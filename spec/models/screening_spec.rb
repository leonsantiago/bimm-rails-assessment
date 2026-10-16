require "rails_helper"

RSpec.describe Screening, type: :model do
  it "defaults to scheduled" do
    expect(described_class.new).to be_scheduled
  end

  [ :external_id, :starts_at, :film, :venue ].each do |attribute|
    it "requires #{attribute}" do
      screening = build(:screening, attribute => nil)

      expect(screening).not_to be_valid
      expect(screening.errors[attribute]).not_to be_empty
    end
  end

  it "requires unique external IDs" do
    screening = create(:screening)
    duplicate = build(:screening, external_id: screening.external_id)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:external_id]).to include("has already been taken")
    expect(screening.reload).to be_valid
  end

  %w[scheduled cancelled].each do |status|
    it "persists the #{status} status" do
      screening = create(:screening, status: status)

      expect(screening.reload.status).to eq(status)
    end
  end

  it "rejects an unknown status on assignment" do
    expect { build(:screening, status: "unknown") }.to raise_error(ArgumentError)
  end
end
