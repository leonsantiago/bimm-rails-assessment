require "rails_helper"

RSpec.describe Film, type: :model do
  it "accepts a valid film" do
    expect(build(:film)).to be_valid
  end

  [ :external_id, :title ].each do |attribute|
    it "requires #{attribute}" do
      film = build(:film, attribute => nil)

      expect(film).not_to be_valid
      expect(film.errors[attribute]).to include("can't be blank")
    end
  end

  it "requires unique external IDs" do
    film = create(:film)
    duplicate = build(:film, external_id: film.external_id)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:external_id]).to include("has already been taken")
    expect(film.reload).to be_valid
  end

  it "allows different films to share a title" do
    film = create(:film)

    expect(build(:film, title: film.title)).to be_valid
  end

  it "associates screenings with their film" do
    screening = create(:screening)

    expect(screening.film.screenings).to contain_exactly(screening)
  end
end
