require "rails_helper"

RSpec.describe ProgrammeSync, "pagination completeness" do
  let!(:retained) do
    create(:screening, external_id: "LOCAL-ONLY",
      film: create(:film, external_id: "LOCAL-FILM"),
      venue: create(:venue, external_id: "LOCAL-VENUE"))
  end

  def paginated_client(&change)
    api_client do |env|
      page = Rack::Utils.parse_query(env.url.query).fetch("page").to_i
      payload = {
        page: page, per_page: 25, total_pages: 3, total_count: 60,
        screenings: MockApi::Dataset.generation_one.slice((page - 1) * 25, 25)
      }
      change.call(payload)
      [ 200, {}, payload.to_json ]
    end
  end

  [ { total_count: 61 }, { total_pages: 4 }, { per_page: 26 } ].each do |change|
    it "fails when #{change.keys.first} changes between pages" do
      client = paginated_client { |payload| payload.merge!(change) if payload[:page] == 2 }

      expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error, /pagination/)

      expect(SyncRun.sole).to have_attributes(status: "failed", screenings_created: 25, last_processed_page: 1)
      expect(Screening.where.not(id: retained.id).count).to eq(25)
      expect(Screening.exists?(retained.id)).to be(true)
    end
  end

  it "rejects a truncated final page without rolling back previous imports" do
    client = paginated_client { |payload| payload[:screenings].pop if payload[:page] == 3 }

    expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error, /incomplete/)

    expect(SyncRun.sole).to have_attributes(status: "failed", screenings_created: 59, last_processed_page: 3)
    expect(SyncRun.sole.finished_at).to be_present
    expect(SyncRun.sole.error_class).to eq("FestivalApiClient::Error")
    expect(Screening.where.not(id: retained.id).count).to eq(59)
    expect(Screening.exists?(retained.id)).to be(true)
  end

  it "rejects an empty intermediate page even if later pages succeed" do
    client = paginated_client { |payload| payload[:screenings] = [] if payload[:page] == 2 }

    expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error, /incomplete/)

    expect(SyncRun.sole).to have_attributes(status: "failed", screenings_created: 35)
    expect(Screening.where.not(id: retained.id).count).to eq(35)
  end

  [ 1, 2 ].each do |duplicate_page|
    it "rejects duplicate IDs #{duplicate_page == 1 ? 'within a page' : 'across pages'}" do
      client = paginated_client do |payload|
        if payload[:page] == duplicate_page
          payload[:screenings][1] = MockApi::Dataset.generation_one.first
        end
      end

      expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error, /duplicate screening IDs/)

      expect(SyncRun.sole).to have_attributes(status: "failed", screenings_created: 59, screenings_unchanged: 1)
      expect(Screening.where.not(id: retained.id).count).to eq(59)
      expect(Screening.exists?(retained.id)).to be(true)
    end
  end

  it "accepts a valid empty response and retains existing screenings" do
    client = api_client do
      [ 200, {}, { page: 1, per_page: 25, total_pages: 0, total_count: 0, screenings: [] }.to_json ]
    end

    run = described_class.new(client: client).call

    expect(run).to have_attributes(status: "succeeded", screenings_created: 0)
    expect(Screening.find(retained.id)).to eq(retained)
  end
end
