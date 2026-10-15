require "rails_helper"

RSpec.describe ProgrammeSync, "run tracking" do
  def run_sync(**params)
    described_class.new(client: api_client, **params).call
  end

  it "persists a running execution before requesting the first page" do
    client = api_client do
      expect(SyncRun.sole).to have_attributes(
        status: "running", finished_at: nil, last_processed_page: 0,
        screenings_created: 0, screenings_updated: 0, screenings_unchanged: 0
      )
      expect(SyncRun.sole.started_at).to be_present
      [ 200, {}, { page: 1, per_page: 25, total_pages: 0, total_count: 0, screenings: [] }.to_json ]
    end

    run = described_class.new(client: client).call

    expect(run.reload).to be_succeeded
    expect(run.finished_at).to be >= run.started_at
  end

  it "records a successful full import and returns its run" do
    run = run_sync

    expect(run).to eq(SyncRun.sole)
    expect(run.reload).to have_attributes(
      status: "succeeded", screenings_created: 60, screenings_updated: 0,
      screenings_unchanged: 0, last_processed_page: 3, error_class: nil, error_message: nil
    )
    expect(run.started_at).to be_present
    expect(run.finished_at).to be >= run.started_at
  end

  it "creates a separate run counting unchanged screenings on repeat execution" do
    first = run_sync
    second = run_sync

    expect(SyncRun.count).to eq(2)
    expect(first.reload.screenings_created).to eq(60)
    expect(second.reload).to have_attributes(
      status: "succeeded", screenings_created: 0, screenings_updated: 0,
      screenings_unchanged: 60, last_processed_page: 3
    )
  end

  it "counts generation two inserts and screening updates" do
    run_sync
    run = run_sync(generation: 2)

    expect(run.reload).to have_attributes(
      status: "succeeded", screenings_created: 2, screenings_updated: 7,
      screenings_unchanged: 52, last_processed_page: 3
    )
  end

  it "preserves tracking and eight committed records when page two fails" do
    expect { run_sync(fail_after: 8) }.to raise_error(FestivalApiClient::TransientError, /HTTP 500/)

    run = SyncRun.sole
    expect(run).to have_attributes(
      status: "failed", screenings_created: 8, screenings_updated: 0,
      screenings_unchanged: 0, last_processed_page: 1,
      error_class: "FestivalApiClient::TransientError"
    )
    expect(run.error_message).to match(/HTTP 500.*page 2/)
    expect(run.finished_at).to be >= run.started_at
    expect(Screening.count).to eq(8)

    retry_run = run_sync
    expect(retry_run).to have_attributes(screenings_created: 52, screenings_unchanged: 8, status: "succeeded")
    expect(run.reload).to be_failed
  end

  it "records failure before any records have been committed" do
    client = api_client { [ 200, {}, "invalid JSON" ] }

    expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error)

    expect(SyncRun.sole).to have_attributes(
      status: "failed", screenings_created: 0, screenings_updated: 0,
      screenings_unchanged: 0, last_processed_page: 0,
      error_class: "FestivalApiClient::Error"
    )
    expect(SyncRun.sole.error_message).to include("invalid JSON")
    expect(SyncRun.sole.finished_at).to be_present
  end

  it "excludes a rolled-back record from counts and does not mark its page complete" do
    records = MockApi::Dataset.generation_one.first(2)
    records.last["starts_at"] = "invalid timestamp"
    client = api_client do
      [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 2, screenings: records }.to_json ]
    end

    expect { described_class.new(client: client).call }.to raise_error(ActiveRecord::RecordInvalid)

    expect(SyncRun.sole).to have_attributes(
      status: "failed", screenings_created: 1, screenings_updated: 0,
      screenings_unchanged: 0, last_processed_page: 0,
      error_class: "ActiveRecord::RecordInvalid"
    )
    expect(SyncRun.sole.error_message).to include("Starts at")
    expect(SyncRun.sole.finished_at).to be_present
    expect(Screening.count).to eq(1)
    expect(Film.exists?(external_id: records.last["film"]["id"])).to be(false)
    expect(Venue.exists?(external_id: records.last["venue"]["id"])).to be(false)
  end

  it "preserves the original synchronization error when saving its failure also fails" do
    original_error = FestivalApiClient::Error.new("upstream unavailable")
    tracking_error = ActiveRecord::StatementInvalid.new("tracking write failed")
    client = instance_double(FestivalApiClient)
    allow(client).to receive(:screenings).and_raise(original_error)
    allow(SyncRun).to receive(:create!).and_wrap_original do |create, **attributes|
      run = create.call(**attributes)
      allow(run).to receive(:update!).with(hash_including(status: :failed)).and_raise(tracking_error)
      run
    end
    expect(Rails.logger).to receive(:error).with(/Could not mark SyncRun .*tracking write failed/)

    expect { described_class.new(client: client).call }.to raise_error { |error| expect(error).to equal(original_error) }
    expect(SyncRun.sole).to be_running
  end

  it "counts created, updated and unchanged records before a mid-page failure" do
    run_sync
    records = MockApi::Dataset.generation_one.first(4)
    records[1]["starts_at"] = "2027-03-22T21:00:00Z"
    records[2]["id"] = "SCR-NEW"
    records[3]["starts_at"] = "invalid timestamp"
    client = api_client do
      [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 4, screenings: records }.to_json ]
    end

    expect { described_class.new(client: client).call }.to raise_error(ActiveRecord::RecordInvalid)

    expect(SyncRun.order(:id).last).to have_attributes(
      status: "failed", screenings_created: 1, screenings_updated: 1,
      screenings_unchanged: 1, last_processed_page: 0
    )
    expect(Screening.count).to eq(61)
    expect(Screening.find_by!(external_id: records[1]["id"]).starts_at).to eq(Time.utc(2027, 3, 22, 21))
    expect(Screening.find_by!(external_id: records[3]["id"]).starts_at).to eq(Time.iso8601(MockApi::Dataset.generation_one[3]["starts_at"]))
  end

  it "keeps the last completed page when a record on a later page is malformed" do
    client = api_client do |env|
      page = Rack::Utils.parse_query(env.url.query).fetch("page").to_i
      records = MockApi::Dataset.generation_one.slice((page - 1) * 25, 25)
      records[1]["venue"] = nil if page == 2
      [ 200, {}, { page: page, per_page: 25, total_pages: 3, total_count: 60, screenings: records }.to_json ]
    end

    expect { described_class.new(client: client).call }.to raise_error(ProgrammeSync::InvalidRecord)

    expect(SyncRun.sole).to have_attributes(
      status: "failed", screenings_created: 26, screenings_updated: 0,
      screenings_unchanged: 0, last_processed_page: 1,
      error_class: "ProgrammeSync::InvalidRecord"
    )
    expect(Screening.count).to eq(26)
  end
end
