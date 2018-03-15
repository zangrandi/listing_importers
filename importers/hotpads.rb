module ListingImporter
  class Hotpads < Base
    include ListingImporterHelper

    def self.valid_url_regexp
      /.*\.?hotpads\.com/
    end

    def self.grab(url)
      return unless valid_url?(url)
      agent = Mechanize.new
      page = agent.get(url)
      html = Nokogiri::HTML(page.body)
      json_data = html.to_s.match(/<script.+?type=\"application\/json\".+?>(.+?)<\/script/m).try(:[], 1) ||
                  html.to_s.match(/<script.+?type=\"application\/ld\+json\".+?data-react-helmet=\"true\".+?>(.+?)<\/script/m).try(:[], 1)
      @json_data = json_data.present? ? JSON.parse(json_data) : {}
      @listing_data = @json_data.dig('ListingEngineStore', 'listingGroups', 'currentListing') ||
                      @json_data.dig('listings', 'buildingCache')&.values&.first.try(:dig, 'units')&.first ||
                      @json_data.dig('listings', 'listingGroups', 'currentListing') ||
                      @json_data.dig('@graph', 0)&.deep_merge(@json_data['@graph'][1]) ||
                      {}

      parse(html) if html.present?
    end

    def self.extract_coordinates(post)
      data = {}

      if coords = @listing_data.dig('geo')
        lat = coords.dig(:lat) || coords.dig('latitude')
        lon = coords.dig(:lon) || coords.dig('longitude')
      else
        coords = post.text.scan(/lat=(.+)&lon=(.+)&zoom/).flatten
        if coords.length == 2
          lat = coords.first
          lon = coords.last
        end
      end

      if lat && lon
        data[:lat]  = lat.try(:to_f)
        data[:long] = lon.try(:to_f)
      end

      data
    end

    def self.extract_address(post)
      data = {}

      data[:unit] = @listing_data.dig('unit').presence

      if full_address = @listing_data.dig('address')
        data[:address] = full_address['street'] || full_address['streetAddress']
        data[:city] = full_address['city'] || full_address['addressLocality']
        data[:state] = full_address['state'] || full_address['addressRegion']
        data[:zip] = full_address['zip'] || full_address['postalCode']
        data[:masking_enable] = true if full_address['hideStreet']
        address_raw = @listing_data['name']
      elsif post.at_css("div.HdpAddress-address-wrapper")
        full_address = post.at_css("div.HdpAddress-address-wrapper")
        data[:city] = full_address.at_css("span[itemprop=addressLocality]").text.strip
        data[:state] = full_address.at_css("span[itemprop=addressRegion]").text.strip
        data[:zip] = full_address.at_css("span[itemprop=postalCode]").text.strip
        address_raw = full_address.at_css("h1.HdpAddress-title > .Utils-text-overflow").text.strip
      else
        address_tag = post.at_css(".street-address")
        if address_tag
          address = address_tag.children.first.try(:text) || address_tag
          data[:address] = address.strip if address

          unit = post.at_css("span.extended-address").try(:text)
          data[:unit] ||= unit.strip.gsub(/\D/, '') if unit
        end

        city_raw = post.at_css("span.locality").try(:text)
        if city_raw
          if city_raw.include? ','
            city = city_raw.split(', ')[0]
            data[:city] = city

            state = city_raw.split(', ')[1].split[0]
            data[:state] = state

            zip = city_raw.split(', ')[1].split[1]
            data[:zip] = zip
          else
            city = city_raw
            data[:city] = city

            state = post.at_css("span.region").try(:text)
            data[:state] = state

            zip = post.at_css("span.postal-code").try(:text)
            data[:zip] = zip
          end
        end
      end

      if data[:unit].blank? && address_raw
        unit_raw = address_raw&.match(/[\s,]#{Regexp.new(Regexp.union(UNIT_TYPES).source, Regexp::IGNORECASE)}\s([\S]+)/i) ||
                   address_raw&.match(/[\s,]\#([\S]+)/) ||
                   address_raw&.match(/\s-\s(.+)/)
        data[:unit] = unit_raw.try(:[], 1)
      end

      data[:address] = address_raw if data[:address].blank?
      data[:address].gsub!(unit_raw[0], '') if unit_raw && address_raw == data[:address]

      data
    end

    def self.extract_facts(post)
      data = {}

      if facts = @listing_data.dig('models').try(:first)
        data[:bedrooms] = facts['beds']
        baths = facts['baths'].to_f.to_s
        data[:full_bathrooms] = baths.split('.').first
        data[:partial_bathrooms] = 1 unless baths.split('.').last.to_i.zero?
        data[:square_feet] = facts['sqft']
      elsif (bed_bath_square_match = post.at_css(".BedsBathsSqft")&.text&.match(/(.*)beds?(.*)baths?(.*)sqft/))
        data[:bedrooms] = bed_bath_square_match[1]&.gsub(/\D/, '')
        baths = bed_bath_square_match[2]&.gsub(/[^\d\.]/, '')&.split('.')
        data[:full_bathrooms] = baths&.first
        data[:partial_bathrooms] = 1 unless baths.try(:[], 1).to_i.zero?
        data[:square_feet] = bed_bath_square_match[3]&.gsub(/\D/, '')
      else
        bedrooms = post.at_css("td.numBeds").try(:text)
        data[:bedrooms] = bedrooms.gsub(/\D/, '') if bedrooms

        # Extract square feet
        square_feet = post.at_css("td.sqft").try(:text)
        data[:square_feet] = square_feet.gsub(/\D/, '') if square_feet

        # Extract bathrooms
        bathrooms = post.at_css("td.numBaths").try(:text)
        data[:partial_bathrooms] = bathrooms.gsub(/[^\d\.]/, '') if bathrooms
      end

      if descr = @listing_data.dig('details', 'fullDescription')
        data[:highlights] = descr
      elsif (descr = post.at_css("div#HdpDescriptionContent"))
        data[:highlights] = descr.text.strip.gsub(/\r/, "\n")
      else
        #Extract highlights
        description = post.at_css("div#fullDescription div.body.description").try(:text)
        data[:highlights] = description.strip.gsub(/\r/, "\n") if description
      end

      data
    end

    def self.extract_title(post)
      title = @listing_data.dig('details', 'title') ||
              post.text.scan(/listingName ?= ?"(.+)";/).flatten.first ||
              @listing_data['description'] ||
              post.title&.split("|")&.first
      title.strip if title
    end

    def self.extract_price(post)
      price = @listing_data.dig('pricing', 'summary', 'priceLow') ||
              @listing_data.dig('offers', 'price') ||
              post.at_css("td.price").try(:text) ||
              post.at_css(".pricing-availability-container .SingleModelHdpHeader-pricing").try(:text)

      price.is_a?(Integer) ? price : price&.gsub(/\D/, '')
    end

    def self.detect_type(post)
      if type = post.at_css("#propertyKeywords").try(:text)
        general_type = Listing::TYPE_RENT['KEY'] if type.match("for Rent")
        general_type = Listing::TYPE_SALE['KEY'] if type.match("for Sale")
      elsif (type = post.at_css(".FeaturedListingsGroup").try(:text))
        general_type = Listing::TYPE_RENT['KEY'] if type.match("For Rent")
        general_type = Listing::TYPE_SALE['KEY'] if type.match("For Sale")
      elsif type = @listing_data.dig('listingType')
        if type == 'rental'
          general_type = Listing::TYPE_RENT['KEY']
        else
          general_type = Listing::TYPE_SALE['KEY']
        end
      end

      general_type
    end

    def self.get_images(post)
      images = []
      image_index = 0

      while image_tag = post.at_css("a#photo#{image_index}") do
        onclick = image_tag[:onclick]
        if onclick
          url = onclick.scan(/.*'(http:\/\/photonet\.hotpads\.com\/.*)',/)
          image_url = url.flatten.first if url
          images << image_url
        end
        image_index += 1
      end

      images
    end

    def self.log_filename
      "hotpads_import.log"
    end
  end
end
