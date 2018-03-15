# encoding: utf-8

require 'spec_helper'

describe ListingImporter::Propertyware, vcr: {
  cassette_name: 'propertyware_importer',
  match_requests_on: [:method, VCR.request_matchers.uri_without_param(:noCacheIE)]
} do
  let(:account)  { create(:user).account }
  let(:provider) { create(:import_provider, uid: url, account: account, name: 'Propertyware') }
  let(:importer) { described_class.new(account, provider: provider) }
  let(:url)      { 'https://app.propertyware.com/pw/website/widgets/config.jsp?wid=200769539' }

  context '#get_rent' do
    let(:properties_response) { [{
      "id" => 1,
      "targetRent" => property_target_rent,
      "startingRent"=> property_starting_rent
    }] }
    let(:unit_response) { {
      "buildingID" => 1,
      "targetRentDescription" => unit_target_rent,
      "startingRentAmount"=> unit_starting_rent,
      "totalArea" => '2,000.00'
    } }
    let(:property_target_rent) { nil }
    let(:property_starting_rent) { nil }
    let(:unit_target_rent) { nil }
    let(:unit_starting_rent) { nil }

    before { importer.instance_variable_set :@properties, properties_response }
    subject { importer.send(:get_rent, unit_response) }

    context 'when unit target rent is present' do
      let(:unit_target_rent) { "<span class=\"boldFont\">Monthly Rent: </span>$1,050.00" }
      let(:unit_starting_rent) { "$1,050.00" }
      let(:property_target_rent) { "$1,050.00 / Month" }
      let(:property_starting_rent) { "$1,050.00" }
      it { is_expected.to eq 1050 }
    end

    context 'when unit target rent is present with square feet format' do
      let(:unit_target_rent) { "$2.55 / Sq Ft ($2,868.75 / Month)" }
      it { is_expected.to eq 2868.75 }
    end

    context 'when unit target rent has zero value' do
      let(:unit_target_rent) { "$0.00" }
      let(:unit_starting_rent) { "$1,050.00" }
      it { is_expected.to eq 1050 }
    end

    context 'when unit target rent is blank' do
      let(:unit_starting_rent) { "$1,050.00" }
      it { is_expected.to eq 1050 }
    end

    context 'when both unit fields are blank and property has target rent' do
      let(:property_target_rent) { "$2.55 / Sq Ft ($2,868.75 / Month)" }
      let(:property_starting_rent) { "$2,800.00" }
      it { is_expected.to eq 2868.75 }
    end

    context 'when both unit fields are blank and property target is eq 0' do
      let(:property_target_rent) { "$0.00" }
      let(:property_starting_rent) { "$2,800.00" }
      it { is_expected.to eq 2800 }
    end

    context 'when both unit fields and property target are blank' do
      let(:property_starting_rent) { "$2,800.00" }
      it { is_expected.to eq 2800 }
    end

    context 'when only unit square feet based rent is avaialbe' do
      let(:unit_target_rent) { "$2.55 / Sq Ft" }
      it { is_expected.to eq 5100 }
    end

    context 'when only property square feet based rent is avaialbe' do
      let(:property_target_rent) { "$2.55 / Sq Ft" }
      it { is_expected.to eq 5100 }
    end

    context 'when all rent fields are blank' do
      it { is_expected.to be_nil }
    end
  end

  it_behaves_like "Details Grabber" do
    let(:additional_details) { [DetailValue.find_by(code: 'NO_PETS')] }
    let(:highlights) { "Incredible one bedroom in the heart of Denver's hottest area. Walk"\
      " into the city or up and down restaurant row. Top floor unit with a great shared pa"\
      "tio! Schedule a Showing! http://ow.ly/4nkw2b"
    }
  end

  context "#get_application_url" do
    before { importer.instance_variable_set :@propertyware_username, "usajrealty" }
    subject { importer.send(:get_application_url, "abc") }

    it "should return correct url" do
      expect(subject).to eql("https://app.propertyware.com/pw/portals/usajrealty/"\
                             "tenantApplication.action?unitID=abc")
    end
  end

  describe "#get_details_list" do
    let(:listing_data) do
      {
        "petsAllowed" => pets_allowed,
        "amenities" => amenities
      }
    end

    let(:parsed_detail_values) { subject[:detail_values].map(&:code) }

    before { importer.prepare_pet_details }

    subject { importer.send(:get_details_list, listing_data) }

    context "'petsAllowed' is 'Yes'" do
      let(:pets_allowed) { "Yes" }

      context "pets data in amenities" do
        let(:amenities) do
          [
            { "id" => "1555988489", "name" => "Dishwasher", "code" => "DSHW", "type" => "Unit" },
            { "id" => "1555988491", "name" => "No cats", "code" => "NOCA", "type" => "Unit" },
            { "id" => "1555988493", "name" => "Dogs negotiable", "code" => "", "type" => "Unit" }
          ]
        end

        let(:expected_detail_values) { ["NO_CATS", "DOGS_NEGOTIABLE", "DISHWASHER"] }

        it "overrides 'petsAllowed' field with pets data from amenities" do
          expect(parsed_detail_values).to match_array(expected_detail_values)
        end
      end

      context "no pet data in amenities" do
        let(:amenities) do
          [{ "id" => "1555988489", "name" => "Dishwasher", "code" => "DSHW", "type" => "Unit" }]
        end

        let(:expected_detail_values) { ["CATS_OK", "DOGS_OK", "DISHWASHER"] }

        it "sets cats and dogs to OK" do
          expect(parsed_detail_values).to match_array(expected_detail_values)
        end
      end
    end

    context "'petsAllowed' is 'No'" do
      let(:pets_allowed) { "No" }

      context "pets data in amenities" do
        let(:amenities) do
          [
            { "id" => "1555988489", "name" => "Dishwasher", "code" => "DSHW", "type" => "Unit" },
            { "id" => "1555988491", "name" => "No cats", "code" => "NOCA", "type" => "Unit" },
            { "id" => "1555988493", "name" => "Dogs negotiable", "code" => "", "type" => "Unit" }
          ]
        end

        let(:expected_detail_values) { ["NO_CATS", "DOGS_NEGOTIABLE", "DISHWASHER"] }

        it "overrides 'petsAllowed' field with pets data from amenities" do
          expect(parsed_detail_values).to match_array(expected_detail_values)
        end
      end

      context "pets negotiable in amenities" do
        let(:amenities) do
          [
            { "id" => "1555988489", "name" => "Dishwasher", "code" => "DSHW", "type" => "Unit" },
            { "id" => "1555988490", "name" => "Pets negotiable", "code" => "", "type" => "Unit" }
          ]
        end

        let(:expected_detail_values) { ["PETS_NEGOTIABLE", "DISHWASHER"] }

        it "sets pets to NO" do
          expect(parsed_detail_values).to match_array(expected_detail_values)
        end
      end

      context "no pet data in amenities" do
        let(:amenities) do
          [{ "id" => "1555988489", "name" => "Dishwasher", "code" => "DSHW", "type" => "Unit" }]
        end

        let(:expected_detail_values) { ["NO_PETS", "DISHWASHER"] }

        it "sets pets to NO" do
          expect(parsed_detail_values).to match_array(expected_detail_values)
        end
      end
    end
  end
end
