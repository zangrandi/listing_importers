require "spec_helper"

describe ListingImporter::Buildium do
  let(:importer) { described_class.new(account, provider: provider) }
  let(:account) { create(:account) }
  let(:agent) { double(:agent, valid?: true, subdomain: "source.domain").as_null_object }

  let!(:provider) {
    create(:import_provider, account: account, name: "Buildium",
           uid: ["test@email.com", "source.domain"].to_json)
  }

  before do
    allow(ListingImporter::Agents::BuildiumAgent).to receive(:new).and_return(agent)
    response = double
    allow(response).to receive(:code).and_return(200)
    allow(response).to receive(:body).and_return("")
    allow(HTTParty).to receive(:get).and_return(response)
  end

  describe "#valid?" do
    context "credentials" do
      it "should to be true if valid" do
        expect(importer.valid?(provider)).to eq(true)
      end

      context "invalid" do
        let(:agent) { double(:agent, valid?: false, subdomain: "source.domain").as_null_object }
        before do
          allow(ListingImporter::Agents::BuildiumAgent).to receive(:new).and_return(agent)
        end

        it "should be false if invalid" do
          provider.uid = {}.to_json
          expect(importer.valid?(provider)).to eq(false)
        end
      end
    end

    context "domain" do
      before { provider.update_attribute :uid, "www.rentme" }

      it "should be true if valid" do
        expect(importer.valid?(provider)).to eq(true)
      end

      context "invalid" do
        before do
          response = double
          allow(response).to receive(:code).and_return(500)
          allow(response).to receive(:body).and_return("Sorry, we can't find")
          allow(HTTParty).to receive(:get).and_return(response)
        end

        it "should be false if invalid" do
          expect(importer.valid?(provider)).to eq(false)
        end
      end
    end
  end

  describe "#validate_uid" do
    it 'should validate correct subdomain' do
      ['www.rentme.managebuilding.com', 'https://www.rentme.managebuilding.com/', 'www.rentme'].each do |link|
        provider.uid = importer.sanitize_uid(link)
        expect { importer.valid?(provider) }.not_to raise_error
        expect(importer.validate_uid(link)).to eq(nil)
      end
    end

    it 'should not validate wrong subdomain' do
      ['www.', 'http://www.managebuilding.com', 'signin.managebuilding.com'].each do |link|
        provider.uid = importer.sanitize_uid(link)
        expect(importer.validate_uid(provider.uid)).not_to eq(nil)
      end
    end
  end

  describe "#sanitize_uid" do
    it 'should correct sanitize with www' do
      expect(importer.sanitize_uid('1www.managebuilding.com')).to eq('1www')
      expect(importer.sanitize_uid('somethingwww.managebuilding.com')).to eq('somethingwww')
    end
  end

  describe ".import" do
    let(:updated_listings) { double }
    let(:missing_listings) { double }

    let(:agent) do
      double(
        :agent,
        valid?: true,
        subdomain: "source.domain",
        parse_listings_attrs: listings_attrs
      ).as_null_object
    end

    let(:listings_attrs) do
      [{
        address: "22nd west",
        zip: "10101",
        bedrooms: 5,
        full_bathrooms: 2
      }]
    end

    subject { importer.import }

    it "imports listings" do
      expect { subject }.to change { account.listings.count }.to(1)
    end

    it "resets when update started" do
      expect { subject }.to change { provider.reload.update_started_at }.to(nil)
    end

    it "sets when update finished" do
      expect { subject }.to change { provider.reload.updated_at }
    end

    context "invalid" do
      before do
        allow(importer).to receive(:valid?).and_return(false)
      end

      context 'credentials' do
        before do
          allow(importer).to receive(:parse_uid).and_return(true)
        end

        it "should send notification if credentials" do
          expect_any_instance_of(Notifiers::ImportProviderNotifier).
            to receive(:send_notification_authentication_failed)
          subject
        end

        it "should return" do
          expect(subject).to eq(nil)
        end
      end

      context 'domain' do
        before do
          allow(importer).to receive(:parse_uid).and_return(false)
        end

        it "should raise error if domain" do
          expect { subject }.to raise_error(Exceptions::Importers::UidInvalid)
        end
      end
    end
  end

  # New feed importer:

  describe "#parse_feed" do
    let(:feed) {
      File.open("#{Rails.root}/spec/fixtures/classes/listing_importer/buildium_feed_kresource1_2016_09_29.xml")
    }
    let(:available_date) { Date.new(2017, 2, 10) }

    before do
      allow(importer).to receive(:parse_available_date).and_return(available_date)
    end

    it 'correctly parses the example feed' do
      VCR.use_cassette 'buildium_feed_kresource1_2016_09_29' do
        expect(importer.send(:parse_feed, feed)).to eq([
          {
            buildium_id: 16224,
            housing_type: "House",
            address: "179 Leisure Cir",
            unit: nil,
            city: "Port Orange",
            state: "FL",
            zip: "32127",
            rent: 1125,
            security_deposit_type: 'SET_AMOUNT',
            security_deposit_value: 1837,
            full_bathrooms: 2,
            bedrooms: 3,
            square_feet: 1500,
            highlights: "Rent this charming home located in a great neighborhood - Port " \
                        "Orange is known for having the best schools in the county! " \
                        "Close to 95, I4, great shopping, restaurants and more! Less " \
                        "than 15 minutes to the beach!\nLarge fenced backyard \nMOVE-in " \
                        "Ready September 10th \nSchools:\nSpruce Creek " \
                        "Elementary\nCreekside Middle School\nSpruce Creek High\nFACTS\n" \
                        "Single Family\n\nFEATURES\nDeck\nFlooring: Tile\nLawn\nParking: " \
                        "Garage - Attached, Garage - Detached, 312 sqft garage\nPatio\n" \
                        "Security deposit $1,837.00",
            calendar_zones_from_import: ['Zone North'],
            listing_groups_from_import: ['Group Gotham'],
            source: 'Buildium',
            images: ["https://manager-prod.s3.amazonaws.com/Documents/118881/a6653107ab5143b49aef1c4dc32487c9.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/4e0ee44390784c8cac9953a01aba67e2.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/9ff3f340ab0a4c7bb955c8d751b7e2df.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/3959f3d4fee54572b28a60f3ef86a4f4.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/6d3001dc2c944236a0ddbee5af60ddc3.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/53220bdfcc7f47d6b28e340e99905863.jpg"],
            detail_values: [DetailValue.find_by(code: 'YARD')],
            video_url: nil,
            available_date: available_date,
            contact_name_from_import: nil,
            contact_phone_from_import: nil,
            contact_email_from_import: nil,
            application_url: nil
          },
          {
            buildium_id: 14729,
            housing_type: "House",
            address: "6343 Palmas Bay",
            unit: nil,
            city: "Port Orange",
            state: "FL",
            zip: "32127",
            rent: 1995,
            security_deposit_type: 'SET_AMOUNT',
            security_deposit_value: 3292,
            full_bathrooms: 2,
            partial_bathrooms: 1,
            bedrooms: 3,
            square_feet: 3037,
            highlights: "LEASE $1,995 a month\nOR\nPossible Lease Option\nOwner will " \
                        "consider smaller house as down payment\n\nLease Option this " \
                        "gorgeous 3 bedroom 2 bath custom home in the exclusive gated " \
                        "community of Palmas Bay Cove inside of Riverwood Plantation. " \
                        "The community is gorgeous!   \n You will enjoy the properties " \
                        "newly remodeled kitchen with beautiful granite countertops, " \
                        "brand new cabinets, brand new stainless steel dishwasher, stove " \
                        "and microwave. The kitchen has an attached dining area.\n  The " \
                        "open kitchen is perfect for entertaining family and guests.  " \
                        "The great room is spacious featuring a beautiful original " \
                        "corner fireplace. Enjoy the elegant French doors leading out " \
                        "to the classic style Florida room.\n  The Master bedroom is " \
                        "spacious with an attached large master bathroom with sky lights " \
                        "allowing natural light in, garden tub, stand up shower and two " \
                        "walk-in closets. \n  The other two bedrooms are spacious as well. " \
                        "Please email or call to schedule a viewing of this beautiful " \
                        "house! \n\nTerms of the contract;\nRent $1,995 a month\nPlease " \
                        "call or email to schedule a viewing of this beautiful property!",
            calendar_zones_from_import: [],
            listing_groups_from_import: [],
            source: 'Buildium',
            images: ["https://manager-prod.s3.amazonaws.com/Documents/118881/c3d6076295b74cc5b2d770b2fc6b46b6.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/99596dcb246541fbb51eafc28e7331d6.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/edd162f3f34f4cf68459d88b6840e07a.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/83f82801398d46fab03190e983219ed5.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/96097036b4654117bf1bbf3919cb2b94.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/f70b387adf954318bccfa475004388b7.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/1341d058d5134905831a0f50285adfe6.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/510d77a8841744f594db968c4795706e.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/8be0fa6986254008ae6320fe1dd18101.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/da075572943f4bfcb70e874d6705e4ce.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/8b08e4d12e134fb8baf6bad9e00bd8ef.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/1b7b76a0d9744656b276dab7e2bf1d32.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/730e35c6bb2e4849968d04d61eb4cf40.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/42c315a68db14c5298d29a813df8cca6.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/64e4a334c4704dfdaecb0147ed777cbf.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/c611572edbe243db898573c036db15f6.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/3fc3e053b15f4310be7dc8e93e76a9ec.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/76b11bfdc9de4d27840e7fa61e3b5ab3.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/68375103a3294e65b882837d066ac449.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/024ef67074384c7a9bf4b549c8e857c7.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/ec3f83ed0ec64b1b8e88722abcebaa46.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/1a307bb2d09b479db4e4b427ccbc7f03.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/97fd0643ec774a15bd976133718fe90c.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/ef23e248a5d04e1b8b3b81796e236fdd.jpg",
                     "https://manager-prod.s3.amazonaws.com/Documents/118881/c539995313a14d1e8b2fb4946cd530e0.jpg"],
            detail_values: [],
            video_url: "//player.vimeo.com/video/183030482",
            available_date: available_date,
            contact_name_from_import: "Laura Gallagher",
            contact_phone_from_import: "13866817424",
            contact_email_from_import: "laura@kresource.com",
            application_url: "https://#{agent.subdomain}.managebuilding.com/Resident/apps/rentalapp/?listingId=14729"
          }
        ])
      end
    end
  end

  describe "#parse_available_date" do
    let(:url) { "https://expertpropertymgmt.managebuilding.com/Resident/public/rentals/46790" }

    it "should parse date from url" do
      VCR.use_cassette "buildium_available_date_parse" do
        page = Nokogiri::HTML(open(url, allow_redirections: :safe))
        expect(importer.send(:parse_available_date, page)).to eql(Date.new(2017, 2, 10))
      end
    end
  end

  describe "address and unit extracting" do
    let(:property) do
      Nokogiri::XML('
                    <?xml version="1.0" encoding="utf-8"?>
                    <Property>
                      <PropertyID>
                        <MarketingName></MarketingName>
                        <Address>
                          <Address></Address>
                        </Address>
                      </PropertyID>
                      <Floorplan>
                        <Name></Name>
                      </Floorplan>
                    </Property>
                    ')
    end

    let(:floorplan) { property.at_css("Floorplan") }
    let(:address) { property.at_css("PropertyID Address") }
    let(:marketing_name) { property.at_css("PropertyID MarketingName") }
    let(:listing_data) { @listing_data ||= { housing_type: "Apartment" } }

    describe "#extract_address" do
      it "selects the correct address: 24-28 Buell Street - BTV - 24 Buell" do
        address.at_css("Address").content = "24 Buell Street"
        expect(importer.send(:extract_address, address)).to eq("24 Buell St")
      end

      it "ignores anything after a dash" do
        address.at_css("Address").content = "111 Irish Settlement - B"
        expect(importer.send(:extract_address, address)).to eq("111 Irish Settlement")
      end

      it "ignores first dash with spaces: 519 - 521 Clarendon Street - 519" do
        address.at_css("Address").content = "519 - 521 Clarendon Street - 519"
        expect(importer.send(:extract_address, address)).to eq("519 - 521 Clarendon St")
      end

      it "allows this address: 346 \"B\" St." do
        address.at_css("Address").content = "346 \"B\" St."
        expect(importer.send(:extract_address, address)).to eq("346 \"B\" St.")
      end

      it "allows this address and unit: 189 Gregory, (upper)" do
        address.at_css("Address").content = "189 Gregory, (upper)"
        expect(importer.send(:extract_address, address)).to eq("189 Gregory")
      end

      it "verifies that the number of address elements does not change: 1541 County Rd 11" do
        address.at_css("Address").content = "1541 County Rd 11"
        expect(importer.send(:extract_address, address)).to eq("1541 County Rd 11")
      end

      it "removes apt from the address: 201 S Hoskins Rd Apt 233" do
        address.at_css("Address").content = "201 S Hoskins Rd Apt 233"
        expect(importer.send(:extract_address, address)).to eq("201 S Hoskins Rd")
      end

      it "removes the unit part when # char is used: 590 Parkview Drive #201" do
        address.at_css("Address").content = "590 Parkview Drive #201"
        expect(importer.send(:extract_address, address)).to eq("590 Parkview Dr")
      end

      it "extracts the correct address from: 5110 Elmhurst, Apartment 7" do
        address.at_css("Address").content = "5110 Elmhurst, Apartment 7"
        expect(importer.send(:extract_address, address)).to eq("5110 Elmhurst")
      end

      it "extracts the correct address from: 4111 Midland - Apt 3" do
        address.at_css("Address").content = "4111 Midland - Apt 3"
        expect(importer.send(:extract_address, address)).to eq("4111 Midland")
      end
    end

    describe "#extract_unit" do
      it "removes the 'Apt' part from the unit" do
        address.at_css("Address")
      end

      it "correctly detects weird unit info: 123 Somestreet Unit B3" do
        address.at_css("Address").content = "221 A St B3"
        floorplan.at_css("Name").content = "221 A Street Unit B3 - 1"
        marketing_name.content = "221 A Street Unit B3 - 1"
        expect(importer.send(:extract_unit, property, floorplan, address, listing_data)).to eq("B3")
      end

      it "correctly detects this unit info: 4314 Melody Lane #107" do
        address.at_css("Address").content = "4314 Melody Lane #107"
        floorplan.at_css("Name").content = "Melody Lane 4314 #107 - 1"
        marketing_name.content = "Melody Lane 4314 #107 - 1"
        expect(importer.send(:extract_unit, property, floorplan, address, listing_data)).to eq("107")
      end

      #it "selects the last part for unit if multiple dashes: 24-28 Buell Street - BTV - 24 Buell" do
      #  address.at_css("Address").content = "24 Buell Street"
      #  floorplan.at_css("Name").content = "24-28 Buell Street - BTV - 24 Buell"
      #  marketing_name.content = "24-28 Buell Street - BTV - 24 Buell"
      #  expect(importer.send(:extract_unit, property, floorplan, address, listing_data)).to eq("24 Buell")
      #end

      it "remove dot after Apt: 1415 E. Ocean View Avenue - Apt. G" do
        address.at_css("Address").content = "1415 E. Ocean View Avenue - Apt. G"
        floorplan.at_css("Name").content = "1415 E. Ocean View Avenue - Apt. G"
        marketing_name.content = "1415 E. Ocean View Avenue - Apt. G"
        expect(importer.send(:extract_unit, property, floorplan, address, listing_data)).to eq("Apt G")
      end
    end
  end
end

