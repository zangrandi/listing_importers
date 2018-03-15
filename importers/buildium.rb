require 'listing_importer/agents/buildium_agent'

module ListingImporter
  class Buildium < ListingImporter::Api
    include ActionView::Helpers::SanitizeHelper

    def import
      unless valid?(provider)
        if parse_uid(provider.uid)
          e = Exceptions::Importers::AuthError.new(provider.id)
          Notifiers::ImportProviderNotifier.new(provider).send_notification_authentication_failed(e)
          return
        else
          raise Exceptions::Importers::UidInvalid.new(provider.id, "subdomain")
        end
      end
      super
    end

    def valid?(provider = nil)
      provider ||= @provider
      if parse_uid(provider.uid)
        agent = Agents::BuildiumAgent.new(provider)
        agent.valid?
      else
        domain_valid?(provider.uid)
      end
    ensure
      agent.quit unless agent.nil?
    end

    def set_domain
      agent = Agents::BuildiumAgent.new(provider)
    ensure
      agent.quit if agent.present?
    end

    def sanitize_uid uid
      unless parse_uid(uid)
        if uid =~ /^(.*[\.\/])?www(\..*)?$/
          is_www = true
          uid.gsub!(/www\.?/, '')
        end
        uid = "http://" + uid unless uid.start_with?("http")
        clean_uid = URI.parse(uid).host&.split(".")&.first
        if clean_uid.present?
          uid = clean_uid
        elsif is_www
          uid = 'www'
        end
      end
      uid
    end

    def validate_uid(uid)
      "Buildium subdomain <strong>#{uid}</strong> invalid" if ['www', 'managebuilding', 'signin'].include?(uid)
    end

    private

    def parse_uid(uid)
      JSON.parse(uid) rescue nil
    end

    def unit_map
      @unit_map ||= {}
    end

    def listings_attrs_with_codes
      listings_attrs.map do |data|
        data.delete(:buildium_unit_id)
        data && data.merge(
          source: code_prefix,
          code: [
            code_prefix,
            data[:address].upcase.gsub(" ", "_"),
            data[:zip],
            data[:bedrooms],
            data[:full_bathrooms],
            data[:unit]
          ].reject(&:blank?).join("-")
        )
      end
    end

    def listings_attrs
      parsed_uid = parse_uid(@provider.uid)
      agent = Agents::BuildiumAgent.new(@provider) if @provider.uid.blank? || parsed_uid.present?

      if parsed_uid.present? && parsed_uid.is_a?(Array)
        response = HTTParty.get(agent.send(:public_listing_page), follow_redirects: false)
        if response.code == 302 && agent.subdomain != "signin"
          @provider.update_column(:uid, agent.subdomain)
          @provider.update_column(:encrypted_password, nil)
          parsed_uid = nil
        end
      end

      if parsed_uid.present? && parsed_uid.is_a?(Array)
        listing_attrs = agent.parse_listings_attrs
        listing_attrs = agent.new_parse_listings_attrs if listing_attrs.empty?
      else
        listing_attrs = listings_attrs_via_feed
      end
      @unit_map = Hash[listing_attrs.map { |a| [a[:buildium_id], a[:buildium_unit_id]] }]
      listing_attrs
    ensure
      agent.present? && agent.quit
    end

    def post_import_processing(listings)
      parsed_uid = parse_uid(@provider.uid)
      return unless parsed_uid.present? && parsed_uid.is_a?(Array)

      agent = Agents::BuildiumAgent.new(@provider)
      listings.each do |l|
        listing = Listing.find_by_uid(l[:uid])

        if listing.present?
          unit_id = unit_map[listing.buildium_id]
          agent.update_buildium_description(listing, unit_id)
        end
      end
    ensure
      agent.present? && agent.quit
    end


    # New code for buildium feed:

    FEED_URL = "https://{DOMAIN}.managebuilding.com/Resident/PublicPages/XMLRentals.ashx"

    def listings_attrs_via_feed
      domain = @provider.uid
      return [] unless domain.present?

      link = FEED_URL.gsub("{DOMAIN}", domain)
      feed = open(link)
      parse_feed(feed)
    end

    def parse_feed feed
      doc = Nokogiri::XML(feed)
      doc = doc.css("PhysicalProperty").first

      doc.css("Property").map do |property|
        floorplan = property.at_css("Floorplan")
        page_link = floorplan.at_css("FloorplanAvailabilityURL")&.text&.strip
        page = Nokogiri::HTML(open(page_link, allow_redirections: :safe)) if page_link

        listing_data = {}
        listing_data[:buildium_id]   = floorplan.at_css("Identification IDValue").text.strip.to_i
        #listing_data[:custom_column_1] = ? Not really needed
        #listing_data[:custom_column_2] = ? Not really needed
        listing_data[:housing_type]  = parse_housing_type(property)
        address = property.at_css("PropertyID Address")
        listing_data[:address]       = extract_address(address)
        listing_data[:unit]          = extract_unit(property, floorplan, address, listing_data)
        listing_data[:city]          = address.at_css("City").text.strip
        listing_data[:state]         = address.at_css("State").text.strip
        listing_data[:zip]           = address.at_css("PostalCode").text.strip
        #listing_data[:street_number] = ? skipping for now

        listing_data[:rent]          = floorplan.at_css("EffectiveRent")[:Min].to_i

        deposit = property.at_css("Deposit Amount ValueRange").try(:[], "Exact")
        deposit_value = deposit.to_s.gsub(/[^0-9.]/,'') if deposit

        security_deposit = produce_security_deposit(listing_data[:rent], deposit_value)

        listing_data[:security_deposit_type] = security_deposit[:type]
        listing_data[:security_deposit_value] = security_deposit[:value]

        bathrooms = parse_bathrooms(floorplan)
        listing_data[:full_bathrooms] = bathrooms[:full]
        listing_data[:partial_bathrooms] = bathrooms[:partial]
        listing_data[:bedrooms]      = parse_bedrooms(floorplan)

        size = floorplan.at_css("SquareFeet")["Max"].to_i
        listing_data[:square_feet]   = size if size > 0
        listing_data[:highlights]    = property.at_css("LongDescription").text.
          gsub(/(www\.)?schedule-a-(showing|viewing)\.com\/lmb\/[a-zA-Z0-9\-]*/, '').
          strip

        listing_data.reject! { |k, v| k != :unit && (v.blank? || v == 0) } # from old importer

        amenities = amenities(property)
        listing_data[:calendar_zones_from_import] = find_calendar_zones(amenities)
        listing_data[:listing_groups_from_import] = find_listing_groups(amenities)

        listing_data[:unit]          = nil unless listing_data[:unit].present?
        listing_data[:source]        = 'Buildium'
        listing_data[:images]        = get_image_links(floorplan)
        listing_data[:detail_values] = get_features(property)
        listing_data[:video_url] = extract_video_url(page)
        listing_data[:available_date] = parse_available_date(page)
        listing_data[:contact_name_from_import] = parse_contact_name_from_import(page)
        listing_data[:contact_phone_from_import] = parse_contact_phone_from_import(page)
        listing_data[:contact_email_from_import] = parse_contact_email_from_import(page)
        listing_data[:application_url] = parse_application_url(page)
        listing_data
      end
    end

    def parse_available_date(page)
      return nil if page.blank?

      date = page.at_css(".unit-detail__available-date")&.text&.strip&.split(" ")&.last
      date ||= page.at_css(".availableDate")&.text&.strip&.split(" ")&.last

      return nil if date.blank?

      begin
        Date.strptime(date, "%m/%d/%Y")
      rescue ArgumentError
        Date.strptime(date)
      end
    end

    def get_image_links(floorplan)
      files = floorplan.css("File").map do |file|
        { file_type: file.at_css("FileType").text.strip,
          rank: file.at_css("Rank").text.strip.to_i,
          src: file.at_css("Src").text.strip
        }
      end
      images = files.select { |file| file[:file_type] == "Photo" }
      images.sort! { |x,y| x[:rank] <=> y[:rank] }
      images.map { |image| image[:src] }
    end

    def get_features(property)
      return [] unless @account.listing_import_details
      codes = []
      amenities(property).each do |feature|
        codes << case feature.upcase
          when 'AIR CONDITIONING'
            'AIR_CONDITIONING'
          when 'BALCONY, DECK, PATIO'
            'PATIO'
          when 'CABLE READY'
            'CABLE_READY'
          when 'CARPORT'
            'CARPORT'
          when 'DISHWASHER'
            'DISHWASHER'
          when 'FENCED YARD'
            'YARD'
          when 'FIREPLACE'
            'FIREPLACE'
          when 'GARAGE PARKING'
            'GARAGE_PARKING'
          when 'HARDWOOD FLOORS'
            'HARDWOOD_FLOORS'
          when 'HIGH SPEED INTERNET'
            'INTERNET_ACCESS_INCLUDED'
          when 'LAUNDRY ROOM / HOOKUPS'
            'LAUNDRY_IN_UNIT'
          when 'MICROWAVE'
            'MICROWAVE'
          when 'OVEN / RANGE'
            'STOVEOVEN'
          when 'REFRIGERATOR'
            'REFRIGERATOR'
          when 'WALK-IN CLOSETS'
            'WALKIN_CLOSET'
          when 'PET FRIENDLY'
            ['DOGS_OK', 'CATS_OK']
        end
      end

      codes.flatten!
      codes.uniq!
      codes.compact!

      codes.map { |code| DetailValue.find_by_code(code) }.compact
    end

    def parse_housing_type(property)
      type = property.at_css("ILS_Identification")[:ILS_IdentificationType]
      case type
      when "Apartment", "Mid Rise", "Duplex", "Triplex", "4plex"
        "Apartment"
      when "Condo"
        "Condo"
      when "House for Rent", "HouseforRent"
        "House"
      when "Townhouse"
        "Townhouse"
      when "Corporate", "Mixed Use"
        "Commercial"
      when "Senior", "Assisted Living", "Subsidized", "High Rise", "Garden Style", "Vacation", "Campus", "Military", "Unspecified"
        "Apartment"
      else
        raise StandardError, "Unknown housing type in buildium feed: #{type}"
      end
    end

    def parse_bathrooms(floorplan)
      bathrooms = floorplan.css("Room").
                    select { |room| room["RoomType"] == "Bathroom" }.
                    first
      bathrooms = bathrooms.at_css("Count").text.split(".")
      {
        full: bathrooms[0].to_i,
        partial: (bathrooms[1].to_i > 0) ? 1 : 0
      }
    end

    def parse_bedrooms(floorplan)
      bedrooms = floorplan.css("Room").
                   select { |room| room["RoomType"] == "Bedroom" }.
                   first
      bedrooms.at_css("Count").text.to_i
    end

    def extract_address(address)
      def process_address(raw)
        parsed_address = StreetAddress::US.parse(raw, { informal: true })
        if parsed_address
          result = [
            parsed_address.number,
            parsed_address.prefix,
            parsed_address.street,
            parsed_address.street_type,
            parsed_address.suffix
          ].compact.join(' ')

          if raw.split(/\s+/).size != result.split(/\s+/).size
            # This is to correct addresses like "1541 Co Rd 11, Mead, NE 68041"
            result = raw
          end
        end
        result
      end
      raw = address.at_css("Address").text.split(/\sapt.?\s/i).first
      raw = raw.gsub(/\s#\S+(\s|$)/, "").strip
      raw = raw.split(",").first
      raw = raw.gsub(/-$/, "").strip
      interm = raw.split(" - ").first
      output = process_address(interm)
      if output.blank?
        interm = raw.split(" - ")[0..-2].join(" - ")
        output = process_address(interm)
      end
      if output.blank?
        interm = raw.split(",").first
        output = process_address(interm)
      end
      if output.blank?
        output = raw.split(" - ").first
      end
      output
    end

    def extract_unit(property, floorplan, address, listing_data)
      raw = address.at_css("Address").text.gsub("Apt.", "Apt")
      unit = raw.split(" - ")[1]&.strip
      unit ||= floorplan.at_css("Name").text.scan(/Unit (\w+)/i)&.first&.first
      unit ||= StreetAddress::US.parse(raw, { informal: true })&.unit
      unit ||= raw.split(",")[1]&.strip
      #unit ||= ([floorplan.at_css("Name").text.split(" - ")[1..-1].last&.strip] - ["1"]).first
      unit = nil if listing_data[:housing_type] == "House"
      unit
    end

    def extract_video_url(page)
      return nil if page.blank?

      script = page.css('script').select { |script_tag| script_tag.text.match(/buildium.dtos/) }.first&.text
      data = script&.match(/(\"Images\":(?<data>.*),\"UnitFeatures\")/).try(:[], 'data')
      if data.present?
        images = JSON.parse data
        images.map do |img|
          if img['ResourceId'].present?
            img['PhysicalFileName'].to_s
          end
        end.compact.first
      end
    end

    def domain_valid?(uid)
      link = base_url_with_subdomain(uid)
      return false if link.blank?
      response = HTTParty.get(link)
      !response.body.include?("Sorry, we can't find")
    end

    def base_url_with_subdomain(uid = nil)
      uid ||= @provider.uid
      parsed_uid = parse_uid(uid)

      domain = if parsed_uid.is_a?(Array)
                 parsed_uid.last
               elsif uid.is_a?(String)
                 uid.strip
               end

      return if domain.blank?
      FEED_URL.gsub("{DOMAIN}", domain)
    end

    def parse_contact_name_from_import(page)
      page.xpath('//footer/div/h2')&.text.presence || fetch_contact_info_from_script(page, 'ContactDescription')
    end

    def parse_contact_phone_from_import(page)
      phone = page.xpath("//footer//a[contains(@href, 'tel:')]")&.text.presence ||
              fetch_contact_info_from_script(page, 'ContactPhone')
      phone&.to_sanitized_phone
    end

    def parse_contact_email_from_import(page)
      page.at_css('footer a.company__email')&.text.presence || fetch_contact_info_from_script(page, 'ContactEmail')
    end

    def fetch_contact_info_from_script(page, field_name)
      info_raw = page.text.match(/buildium.dtos = {[\s\S]+?listingDetails : ({[\s\S]+?)};/).try(:[], 1)
      return unless info_raw

      info = JSON.parse(info_raw)
      info[field_name] if info
    end

    def parse_application_url(page)
      link = page.xpath('//a[text()="Apply for this property"]/@href')&.text.presence ||
               page.xpath('//a[text()="Apply for this unit"]/@href')&.text.presence

      return if link.blank?

      URI.join(base_url_with_subdomain, link.gsub("../", "/Resident/")).to_s
    end

    def amenities(property)
      property.css("Amenity Description").map { |amenity| amenity.text.strip }
    end
  end
end
