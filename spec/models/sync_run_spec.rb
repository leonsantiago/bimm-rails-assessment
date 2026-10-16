require "rails_helper"

RSpec.describe SyncRun, type: :model do
  it "defaults to running with zero counters and no completion time" do
    run = described_class.new(started_at: Time.current)

    expect(run).to be_valid
    expect(run).to have_attributes(status: "running", finished_at: nil,
      screenings_created: 0, screenings_updated: 0, screenings_unchanged: 0, last_processed_page: 0)
  end

  it "requires a start time" do
    run = described_class.new

    expect(run).not_to be_valid
    expect(run.errors[:started_at]).to include("can't be blank")
  end

  %w[running succeeded failed].each do |status|
    it "persists the #{status} status" do
      run = described_class.create!(started_at: Time.current, status: status)

      expect(run.reload.status).to eq(status)
    end
  end

  it "validates unknown statuses rather than raising on assignment" do
    run = described_class.new(started_at: Time.current, status: "unknown")

    expect(run).not_to be_valid
    expect(run.errors[:status]).to include("is not included in the list")
  end

  [ :screenings_created, :screenings_updated, :screenings_unchanged, :last_processed_page ].each do |attribute|
    it "requires #{attribute} to be a non-negative integer" do
      [ nil, -1, 1.5, "invalid" ].each do |value|
        run = described_class.new(started_at: Time.current, attribute => value)

        expect(run).not_to be_valid
        expect(run.errors[attribute]).not_to be_empty
      end

      [ 0, 1 ].each do |value|
        expect(described_class.new(started_at: Time.current, attribute => value)).to be_valid
      end
    end
  end
end
