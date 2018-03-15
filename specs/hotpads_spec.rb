require "spec_helper"

describe ListingImporter::Hotpads, vcr: { cassette_name: "hotpads_listings2" } do
  subject { described_class }

  it_behaves_like "Listing Grabber"do
    let(:listing_url) { "http://hotpads.com/listing/415946" }
    let(:invalid_url) { "http://not-hotpads-at-all.com/12355" }
    let(:sale_listing_url) { "http://hotpads.com/listing/745930" }
    let(:images_in_post) { ["http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0001_1634906510_medium.jpg",
                            "http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0002_218716590_medium.jpg",
                            "http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0003_938410934_medium.jpg",
                            "http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0004_950010318_medium.jpg",
                            "http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0005_1039972111_medium.jpg",
                            "http://photonet.hotpads.com/search/listingPhoto/HotPads/415946/0006_1129933904_medium.jpg"
    ] }
    let(:result) { {
        rent: "3150",
        bedrooms: "2",
        square_feet: "1000",
        title: "2 Bed Walkup in the Heart of Bucktown :: Free Wifi",
        address: "2316 W Belden Avenue",
        unit: "2",
        city: "Chicago",
        state: "IL",
        zip: "60647",
        lat: 41.9235141,
        long: -87.6859943
    } }

    describe "additional fields" do
      before do
        subject.stub(:get_images).and_return([])
        @data = subject.grab(listing_url)
      end

      it "returns partial bathrooms" do
        @data[:partial_bathrooms].should == "1.0"
      end

      it "returns listing highligts" do
        @data[:highlights].should == "Available May 1, 2011 \n773-598-5427 \nSchedule a Showing Online: http://beta.showmojo.com/s/?m=71\n\n. Looks out onto Holstein Park (pool, new playground, basketball courts, baseball diamonds and lots of grass) \n. Walking distance to Target, grocery stores, gym, movies and lots of other shopping \n. Four blocks to the Blue Line Western Station (fast access to the loop) \n. Close to North and Damen nightlife \n. Easy access to the Kennedy (90-94) \n. One bedroom fits a queen size bed. Second bedroom fits a full size. \n\nAmenities and Utilities\t\n. Central heat\t\n. Central air conditioning\t\n. Laundry on-site \n. Dishwasher \n. Free high-speed internet\t\n. Parking Available"
      end
    end
  end

  it_behaves_like "Listing Grabber" do
    let(:listing_url) { "https://hotpads.com/longview-apartments-columbus-oh-43203-sm9x80/pad" }
    let(:invalid_url) { "http://not-hotpads-at-all.com/12355" }
    let(:sale_listing_url) { "http://hotpads.com/listing/745930" }
    let(:images_in_post) { [
    ] }
    let(:result) { {
      general_type: "RENT",
      rent: 525,
      title: "Longview Apartments, Columbus, OH 43203 - HotPads",
      bedrooms: "2",
      full_bathrooms: "1",
      square_feet: "665",
      highlights: "$525/month 2 bedroom with free WiFi!\n\nGorgeous 2 bedroom/1 bath flats"\
        " located in the beautiful Woodland Park area. This property is also within close "\
        "proximity to Franklin Park, the Columbus Metropolitan Library (Martin Luther King"\
        " Branch), OSU Hospital East, Wolfe Park, the YMCA (Eldon & Eisie Ward Family Bran"\
        "ch), 5 minute drive to Bexley and conveniently located on the #16 bus line. Bonus"\
        " features of the apartments include free Wifi, on-site laundry facilities, ample "\
        "off street parking, outdoor bike rack, and window air conditioner units. Cats are"\
        " welcome, but please NO DOGS.",
      address: "1728 E Long Street",
      city: "Columbus",
      state: "OH",
      zip: "43203"
    } }
  end

  it_behaves_like "Listing Grabber", vcr: { cassette_name: "hotpads_listings4"} do
    let(:listing_url) { "https://hotpads.com/9029-nw-57th-st-kansas-city-mo-64152-1sqbskh/pad" }
    let(:invalid_url) { "http://not-hotpads-at-all.com/12355" }
    let(:sale_listing_url) {}
    let(:images_in_post) { [] }
    let(:result) { {
      general_type: "RENT",
      rent: "630",
      title: "9029 NW 57th Street, Parkville, MO 64152",
      bedrooms: "2",
      full_bathrooms: "1",
      square_feet: "",
      address: "9029 NW 57th Street",
      unit: nil,
      city: "Parkville",
      state: "MO",
      zip: "64152"
    } }
  end

  it_behaves_like "Listing Grabber", vcr: { cassette_name: "hotpads_listings5" } do
    let(:listing_url) { "https://hotpads.com/20814-raymond-st-maple-heights-oh-44137-vc5b5m/pad" }
    let(:invalid_url) { "http://not-hotpads-at-all.com/12355" }
    let(:sale_listing_url) {}
    let(:images_in_post) { [] }
    let(:result) { {
      general_type: "RENT",
      rent: 899,
      title: "Home for Rent at 20814 Raymond Street: 2 beds, $899. Map it and view 19 photos and details on HotPads",
      bedrooms: "2",
      full_bathrooms: "1",
      square_feet: "961",
      highlights: "Welcome to 20814 Raymond st. This cozy home includes two spacious bedrooms with one bath "\
        "room. This house includes central air perfect for those hot summer days. A dish washer. A large fen"\
        "ced in back yard, perfect for summer cook outs. A two car garage to store your car in. Large eat in"\
        " kitchen. High way access. Hurry up and schedule a showing today! This home won't last long. \n \nV"\
        "ideo tour:  COMING SOON\n \nAvailability: Visit http\nOhioRental.info to schedule online or call 44"\
        "0-484-5800 for convenient and quick showing.\n\n \nPets: This home is pet friendly. Cost of pet is "\
        "$35 per animal per month. Dogs on the insurance ban list not allowed. \n \nUtilities: Tenant pays w"\
        "ater, sewer, trash, gas, electric, internet and phone.\n \nAppliances:  Dish Washer \n \nParking: 2"\
        " car garage. \n\nSection 8: Section 8 vouchers will not be accepted at this property.\n\n*Tenant In"\
        "surance: Landlord insurance never covers tenant property so proof of tenant insurance is required b"\
        "efore move in. We have found it very much appreciated by tenants and it gives peace of mind. It can"\
        " usually be purchased for a minimal amount of money.\n \n*Application and Screening:  All applicant"\
        "s over 18 must fill out an application and pay application fee of $35. The property will continue t"\
        "o be offered until Realty Trust Services is in possession certified funds to hold property from an "\
        "APPROVED applicant.  We screen on multiple dimensions with an eye to see why and how applicants cou"\
        "ld, in fact, be great tenants. If you want this home please apply! The landlord may make screening "\
        "exceptions in exchange for alternative terms.   \n \n*Property Condition: Most properties are rente"\
        "d as is. If you wouldn't rent this property without specific changes made then do not reserve the p"\
        "roperty unless those are agreed upon in writing.  All information in this ad is deemed accurate but"\
        " the tenant is responsible for inspecting property make sure it is acceptable. Many websites that h"\
        "ave our listings, merge inaccurate information in with our listing. It is especially important that"\
        " you verify important information like the existence of appliances or existence of a working AC uni"\
        "t.\n \n*For Rent: All Realty Trust Services homes for rent are available at http\nOhioRental.info",
      unit: nil,
      address: "20814 Raymond Street",
      city: "Maple Heights",
      state: "OH",
      zip: "44137",
      lat: 41.421592885656,
      long: -81.533584263485
    } }
  end
end
