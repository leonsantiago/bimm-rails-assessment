require "rails_helper"

RSpec.describe Venue, type: :model do
  it "accepts a valid venue" do
    expect(build(:venue)).to be_valid
  end

  [ :external_id, :name ].each do |attribute|
    it "requires #{attribute}" do
      venue = build(:venue, attribute => nil)

      expect(venue).not_to be_valid
      expect(venue.errors[attribute]).to include("can't be blank")
    end
  end

  it "requires unique external IDs" do
    venue = create(:venue)
    duplicate = build(:venue, external_id: venue.external_id)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:external_id]).to include("has already been taken")
    expect(venue.reload).to be_valid
  end

  it "allows different venues to share a name" do
    venue = create(:venue)

    expect(build(:venue, name: venue.name)).to be_valid
  end

  it "associates screenings with their venue" do
    screening = create(:screening)

    expect(screening.venue.screenings).to contain_exactly(screening)
  end
end
