require 'street_address'

class ListingImporter::Propertyware < ListingImporter::Api
  include ListingImporterHelper
  include ActionView::Helpers::SanitizeHelper

  UID_FORMAT = /http(s)?:\/\/app.propertyware.com\/pw\/website\/widgets\/config.jsp\?wid=\d+/

  attr_reader \
      :sid,
      :wid

  PROPERTYWARE_URL =
      'https://app.propertyware.com/pw/website/widgets/config.jsp?wid='
  RENT_REGEXP = /\$([\d,\.]+)\s?\/\s?mo/i
  SQF_RENT_REGEXP = /^\$([\d,\.]+)\s?\/\s?Sq\s?Ft$/
  PROPERTYWARE_UID_FORMAT = /http(s)?:\/\/app.propertyware.com\/pw\/website\/widgets\/config.jsp\?wid=\d+/

  def import
    @wid = @sid = nil
    prepare_pet_details
    prepare_for_import
    super
  end

  def prepare_pet_details
    @pet_codes ||= DetailValueSet.find_by_code("PET_POLICY").detail_values.pluck(:code)
    @dog_codes ||= DetailValueSet.find_by_code("DOG_POLICY").detail_values.pluck(:code)
    @cat_codes ||= DetailValueSet.find_by_code("CAT_POLICY").detail_values.pluck(:code)
  end

  def prepare_for_import
    # Get identifiers from a page with the widget
    page = parse_page_with_widget(provider.uid)

    # Check iframes for widget page
    if page && !(@wid && @sid)
      page.xpath('//iframe/@src').each do |iframe_src|
        parse_page_with_widget(iframe_src.value)

        break if @wid && @sid
      end
    end


    if (!provider.uid.start_with?(PROPERTYWARE_URL) &&
                                  @wid.present? && @sid.present?)

      provider.uid = PROPERTYWARE_URL + @wid.to_s
      provider.save!
    end

    unless @wid.present? && @sid.present?
      raise StandardError,
        "Could not find SID and/or WID for accessing propertyware data on the following page:\n" \
        + provider.uid
    end
  end

  def has_listing_id? id
    prepare_for_import
    has_id = get_data_from(listing_url(id), "loadDetailCallback") rescue nil
    return !!has_id
  end

  def validate_uid uid
    "Propertyware widget <strong>#{uid}</strong> invalid" unless uid[PROPERTYWARE_UID_FORMAT]
  end

  def sanitize_uid uid
    uid[UID_FORMAT] || uid
  end

  private

  def parse_page_with_widget(page_url)
    page_url.strip!
    page_url = "http://#{page_url}" unless page_url =~ /^https?:/

    print "#{page_url}\n"
    page_with_widget = Nokogiri::HTML(custom_fetch(page_url))
    get_sid_wid(page_with_widget)

    page_with_widget
  end

  def get_sid_wid(page)
    @propertyware_username = page.text.try(:match, /https:\/\/app.propertyware.com\/pw\/portals\/(.+)\//)
                                      .try(:[], 1)
    if page.text.match(/var SID =  (\d+);/) && page.text.match(/var WID =  (\d+);/)
      @sid = page.text[/var SID =  (\d+);/, 1]
      @wid = page.text[/var WID =  (\d+);/, 1]
      return
    end
    config_link = page.css('script').detect do |s|
      s[:src] =~ /\/config.jsp/
    end
    if config_link.nil?
      brochure_link = page.css('a.brochure').first
      if brochure_link.present?
        link = brochure_link[:href]
        @sid = link.scan(/sid=(\d+)/)[0][0]
        @wid = link.scan(/wid=(\d+)/)[0][0]
      end
    else
      config = custom_fetch(config_link[:src])
      @sid = config[/var SID =  (\d+);/, 1]
      @wid = config[/var WID =  (\d+);/, 1]
    end
  end

  def listings_attrs_with_codes
    listings_attrs.map do |data|
      data.merge(source: code_prefix,
                 code: [code_prefix,
                        data[:address].upcase.gsub(' ', '_'),
                        data[:zip],
                        data[:bedrooms],
                        data[:full_bathrooms],
                        data[:unit]].reject(&:blank?).join('-')) if data
    end
  end

  def listings_attrs
    all_data = []

    page_number = 0

    while true do
      search_data = get_data_from search_url(page_number), "loadListCallback"

      break unless search_data

      @properties = search_data["buildings"]
      #all_data << Parallel.map(@properties, in_threads: 5) do |listing|
      all_data << @properties.map do |listing|
                    #ActiveRecord::Base.connection_pool.with_connection do
                      get_listing(listing["id"])
                    #end
                  end

      break if (search_data["unitCount"].to_i / search_data["pageSize"].to_i) == page_number
      page_number = page_number + 1
    end

    all_data.flatten.compact
  end

  def get_listing(uid, unit_name = nil)
    listing_data = get_data_from listing_url(uid), "loadDetailCallback"

    return unless listing_data

    if listing_data["unit"]["publishedUnits"].any?
      listing_data["unit"]["publishedUnits"].map do |unit|
        get_listing(unit["id"], unit["name"])
      end
    else
      amenities = listing_data["unit"]["amenities"].map {|amenity| amenity['name']}
      res = {
        propertyware_id: listing_data["unit"]["id"],
        contact_name_from_import: listing_data.dig("unit", "leasingAgent", "name"),
        contact_phone_from_import: listing_data.dig("unit", "leasingAgent", "phone")&.to_sanitized_phone,
        contact_email_from_import: listing_data.dig("unit", "leasingAgent", "email"),
        title: listing_data["unit"]["postingTitle"],
        highlights: get_highlights( listing_data["unit"] ),
        address: listing_data["unit"]["address"],
        city: listing_data["unit"]["city"],
        state: normalize_state( listing_data["unit"]["state"]),
        zip: listing_data["unit"]["zip"],
        rent: get_rent(listing_data["unit"]),
        bedrooms: listing_data["unit"]["numberBedrooms"],
        full_bathrooms: listing_data["unit"]["numberBathrooms"].to_i,
        partial_bathrooms: get_partial_bathrooms( listing_data["unit"]["numberBathrooms"]),
        square_feet: get_square_feet(listing_data["unit"]),
        images: get_images( listing_data["unit"]["images"]),
        video_url: listing_data["unit"]["embeddedHTMLCode"],
        detail_values: get_details( listing_data["unit"] ),
        calendar_zones_from_import: find_calendar_zones(amenities),
        listing_groups_from_import: find_listing_groups(amenities),
        housing_type: get_type(listing_data["unit"]["type"]),
        application_url: get_application_url(listing_data["unit"]["id"])
      }
      res[:unit] = unit_name if unit_name.present?
      res[:lat] = listing_data["unit"]["latitude"] if listing_data["unit"]["latitude"].present?
      res[:long] = listing_data["unit"]["longitude"] if listing_data["unit"]["longitude"].present?
      if listing_data['unit']['availableDateDesc'] == 'Today'
        res[:available_type] = 'Immediate'
      else
        res[:available_date] = listing_data["unit"]['availableDate']
        res[:available_type] = "Date"
      end

      if listing_data['unit']['targetDeposit'].present?
        target_deposit = parse_number(listing_data['unit']['targetDeposit'])
        security_deposit = produce_security_deposit(res[:rent], target_deposit)

        res[:security_deposit_type] = security_deposit[:type]
        res[:security_deposit_value] = security_deposit[:value]
      end

      res
    end
  end

  def get_application_url(propertyware_id)
    if @propertyware_username.present?
      "https://app.propertyware.com/pw/portals/#{@propertyware_username}"\
      "/tenantApplication.action?unitID=#{propertyware_id}"
    end
  end

  def get_rent(unit)
    unit_target_rent = unit['targetRentDescription']
    unit_starting_rent = unit['startingRentAmount']

    unit_rent_values = [
      unit_target_rent&.match(RENT_REGEXP).try(:[], 1),
      unit_target_rent,
      unit_starting_rent&.match(RENT_REGEXP).try(:[], 1),
      unit_starting_rent
    ]

    unit_rent = unit_rent_values.map do |rent_value|
      rent_value = rent_value&.to_s unless rent_value.is_a? String
      rent_value&.match(SQF_RENT_REGEXP).nil? && parse_number(rent_value)&.nonzero?
    end.compact.first

    return unit_rent if unit_rent

    # getting property rent value if unit rent value is empty

    building_id = unit["buildingID"] || unit["publishedFloorPlans"]&.first.try(:[], "buildingID") || unit["id"]
    property_data = @properties.detect { |property| property['id'] == building_id }
    property_target_rent = property_data['targetRent']
    property_starting_rent = property_data['startingRent']

    property_rent_values = [
      property_target_rent&.match(RENT_REGEXP).try(:[], 1),
      property_target_rent,
      property_starting_rent&.match(RENT_REGEXP).try(:[], 1),
      property_starting_rent
    ]

    property_rent = property_rent_values.map do |rent_value|
      rent_value = rent_value&.to_s unless rent_value.is_a? String
      rent_value&.match(SQF_RENT_REGEXP).nil? && parse_number(rent_value)&.nonzero?
    end.compact.first

    return property_rent if property_rent

    # getting rent value from rent field like "$2.55 / Sq Ft"

    sqf_rent_value = (unit_rent_values + property_rent_values).map do |rent_value|
      rent_value = rent_value&.to_s unless rent_value.is_a? String
      parse_number( rent_value&.strip&.match(SQF_RENT_REGEXP).try(:[], 1) )&.nonzero?
    end.compact.first

    square_feet = get_square_feet(unit)
    rent = (sqf_rent_value * square_feet).round(2) if sqf_rent_value && square_feet

    rent
  end

  def get_partial_bathrooms str
    fb, pb = str.split('.')
    return 1 if pb
  end

  def parse_number str
    str ||= ""
    str.gsub(/[^\d\.\-]/, '').to_f
  end

  def get_square_feet unit
    square_feet = unit["totalArea"]
    square_feet&.delete!(',') if square_feet.is_a? String
    square_feet&.to_f&.nonzero?
  end

  def get_images(images)
    images.map {|i| i["highResUrl"]}
  end

  def get_details(listing_data)
    get_details_list(listing_data)[:detail_values]
  end

  def get_highlights(listing_data)
    highlights = sanitize(listing_data["comments"].gsub(/\r/, "").gsub(/<br \/>/, "\n"))
    to_highlights = get_details_list(listing_data)[:to_highlights]
    [highlights, to_highlights].reject(&:blank?).join("\n\n")
  end

  def get_details_list(listing_data)
    details_list = listing_data["amenities"].map {|amenity| amenity['name']}
    details = find_detail_values(amenities: details_list,
                                 advanced: account.advanced_listing_detail_identification?)

    parsed_codes = details[:detail_values].map(&:code)
    pets_added = parsed_codes.any? { |c| c.in?(@pet_codes) }
    dogs_added = parsed_codes.any? { |c| c.in?(@dog_codes) }
    cats_added = parsed_codes.any? { |c| c.in?(@cat_codes) }

    case listing_data["petsAllowed"]
    when "Yes"
      details[:detail_values] += DetailValue.where(code: "CATS_OK") unless cats_added
      details[:detail_values] += DetailValue.where(code: "DOGS_OK") unless dogs_added
    when "No"
      details[:detail_values] << DetailValue.find_by(code: 'NO_PETS') unless pets_added || dogs_added || cats_added
    end

    details[:detail_values] = [] unless account.listing_import_details
    details[:detail_values].uniq_by!(&:code)
    details
  end

  def get_available_date(date_hash)
    date_hash['availableDate']
  end

  def get_type(type_str)
    patterns = {
      /TH|Townhouse/i                 => "Townhouse",
      /Condo/i                        => "Condo",
      /Home|House|SFH|Single Family/i => "House",
      /Apartment/i                    => "Apartment"
    }

    type = "Apartment" # by default
    patterns.each do |p, t|
      if type_str.match(p)
        type = t
        break
      end
    end

    type
  end

  def normalize_state(state)
    if state.length < 3
      state.upcase
    else
      StreetAddress::US::States::STATE_CODES[state.downcase] ||
        AddressBehavior::Canada::STATE_CODES[state.downcase]
    end
  end

  def search_url(page_number=0)
    "https://webreq.propertyware.com/pw/marketing/website.do" \
        "?sid=#{sid}" \
        "&wid=#{wid}" \
        "&forSale=false" \
        "&action=l" \
        "&pageNumber=#{page_number}" \
        "&callback=loadListCallback" \
        "&noCacheIE=#{random}"
  end

  def listing_url(uid)
    "https://webreq.propertyware.com/pw/marketing/website.do" \
        "?sid=#{sid}" \
        "&wid=#{wid}" \
        "&uid=#{uid}" \
        "&action=u" \
        "&sid=#{sid}" \
        "&forSale=false" \
        "&callback=loadDetailCallback" \
        "&noCacheIE=#{random}"
  end

  def get_data_from url, callback
    jsonp = custom_fetch(url)

    # Remove surrounding jsonp function
    jsonp.gsub!(/#{callback}\(/,'')
    jsonp.gsub!(/\)\s*$/,'')
    jsonp.gsub!(/,\s+}/,'}')
    jsonp.gsub!(/\\>/, "\\>")
    jsonp.gsub!(/\t/, "")
    return nil if jsonp.empty?

    begin
      JSON.parse(jsonp)
    rescue JSON::ParserError => e
      if jsonp.include? "img.thumbnailID is undefined."
        notify_support_about_error(e, jsonp)
        raise StandardError, "Skip notification"
      else
        raise e
      end
    end
  end

  def custom_fetch url
    attempt = 0
    begin
      attempt += 1
      if url.start_with?("http://")
        uri = URI.parse url
        http = Net::HTTP.new(uri.host, uri.port)
        res = http.get(uri.request_uri)
        if res.code == "301" || res.code == "302"
          custom_fetch(res.header['location'])
        else
          res.read_body
        end
      else
        # Solves issues with SSL and Propertyware
        uri = URI.parse url
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, ssl_version: :TLSv1) do |http|
          req = Net::HTTP::Get.new(uri)
          http.request(req).read_body
        end
      end
    rescue Errno::ETIMEDOUT => e
      attempt >= 3 ? raise(e) : retry
    end
  end

  def random
    rand.to_s[2..14] # random 13 digit length number
  end

  def notify_support_about_error e, jsonp
    address = jsonp.scan(/"address":"([^"]*)"/)&.first&.first
    if KnownException.
       where(exception_type: KnownException::PROPERTYWARE_THUMBNAIL_ID_ERROR).
       where("created_at > ?", 2.days.ago).
       where("data like '%provider_id: #{provider.id}\n%'").
       select { |ke| ke.data[:data][:address] == address }.empty?
      ex = StandardError.new("unexpected token at ...")
      ex.set_backtrace(e.backtrace)
      provider_account = provider.account
      owner = provider_account.try(:owner)
      exception_data = {
        email: owner.try(:email),
        account_name: owner.try(:name),
        message: "Error importing Listings from #{provider.name}",
        provider_id: provider.id,
        account_id: provider_account.try(:id),
        address: address,
        json: jsonp
      }
      AlertMailer.propertyware_error(ex, exception_data).deliver
      KnownException.record(ex, { :data => exception_data },
                            KnownException::PROPERTYWARE_THUMBNAIL_ID_ERROR)
    end
  end
end