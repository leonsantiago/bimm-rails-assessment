require "rails_helper"

RSpec.describe ProgrammeSyncJob, type: :job do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before { clear_enqueued_jobs }
  after { clear_enqueued_jobs }

  it "enqueues on the default queue with the selected generation" do
    expect { described_class.perform_later(generation: 2) }
      .to have_enqueued_job(described_class).with(generation: 2).on_queue("default")
  end

  it "delegates synchronization with generation one by default" do
    sync = instance_double(ProgrammeSync, call: nil)
    expect(ProgrammeSync).to receive(:new).with(generation: 1).and_return(sync)
    expect(sync).to receive(:call)

    described_class.perform_now
  end

  it "forwards the selected generation" do
    sync = instance_double(ProgrammeSync, call: nil)
    expect(ProgrammeSync).to receive(:new).with(generation: 2).and_return(sync)
    expect(sync).to receive(:call)

    described_class.perform_now(generation: 2)
  end

  it "schedules a transient failure for retry after thirty seconds with the same arguments" do
    sync = instance_double(ProgrammeSync)
    allow(ProgrammeSync).to receive(:new).with(generation: 2).and_return(sync)
    allow(sync).to receive(:call).and_raise(FestivalApiClient::TransientError, "HTTP 503")

    freeze_time do
      expect { described_class.perform_now(generation: 2) }
        .to have_enqueued_job(described_class).with(generation: 2).at(30.seconds.from_now)
    end
  end

  it "stops after three total attempts without falling back to Sidekiq retries" do
    sync = instance_double(ProgrammeSync)
    error = FestivalApiClient::TransientError.new("upstream unavailable")
    allow(ProgrammeSync).to receive(:new).and_return(sync)
    allow(sync).to receive(:call).and_raise(error)

    described_class.perform_now(generation: 2)
    2.times do |attempt|
      retry_payload = enqueued_jobs.shift
      expect(retry_payload).to be_present
      if attempt.zero?
        ActiveJob::Base.execute(retry_payload)
      else
        expect { ActiveJob::Base.execute(retry_payload) }.to raise_error { |raised| expect(raised).to equal(error) }
      end
    end

    expect(sync).to have_received(:call).exactly(3).times
    expect(enqueued_jobs).to be_empty
    expect(described_class.get_sidekiq_options["retry"]).to be(false)
  end

  [ FestivalApiClient::Error, ProgrammeSync::InvalidRecord, ActiveRecord::RecordInvalid ].each do |error_class|
    it "does not retry deterministic #{error_class} failures" do
      sync = instance_double(ProgrammeSync)
      allow(ProgrammeSync).to receive(:new).and_return(sync)
      allow(sync).to receive(:call).and_raise(error_class)

      expect { described_class.perform_now }.to raise_error(error_class)
      expect(enqueued_jobs).to be_empty
    end
  end

  it "retains the failed SyncRun and creates a new one on retry" do
    requests = 0
    client = api_client do
      requests += 1
      if requests == 1
        [ 503, {}, "unavailable" ]
      else
        [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 1,
          screenings: MockApi::Dataset.generation_two.first(1) }.to_json ]
      end
    end
    allow(FestivalApiClient).to receive(:new).and_return(client)

    described_class.perform_now(generation: 2)
    failed_run = SyncRun.sole
    expect(failed_run).to be_failed
    expect(failed_run.error_class).to eq("FestivalApiClient::TransientError")

    ActiveJob::Base.execute(enqueued_jobs.shift)

    expect(SyncRun.count).to eq(2)
    expect(failed_run.reload).to be_failed
    expect(SyncRun.order(:id).last).to have_attributes(status: "succeeded", screenings_created: 1)
    expect(Screening.sole.venue.external_id).to eq("VEN-06")
    expect(enqueued_jobs).to be_empty
  end
end
