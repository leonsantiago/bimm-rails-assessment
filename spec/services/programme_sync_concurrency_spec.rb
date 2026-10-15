require "rails_helper"

RSpec.describe ProgrammeSync, "concurrency protection" do
  let(:lock_key) { described_class::ADVISORY_LOCK_KEY }

  around do |example|
    config = ApplicationRecord.connection_db_config.configuration_hash
    @other_session = PG.connect(
      host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password]
    )
    example.run
  ensure
    @other_session&.close
  end

  def other_session_can_lock?
    acquired = @other_session.exec("SELECT pg_try_advisory_lock(#{lock_key})").getvalue(0, 0) == "t"
    @other_session.exec("SELECT pg_advisory_unlock(#{lock_key})") if acquired
    acquired
  end

  it "holds the lock during HTTP requests and between screening transactions, then releases it" do
    owner = ApplicationRecord.connection
    expect(@other_session.backend_pid).not_to eq(owner.select_value("SELECT pg_backend_pid()"))
    transaction_depth = owner.open_transactions
    requests = 0
    client = api_client do |env|
      requests += 1
      expect(ApplicationRecord.connection).to equal(owner)
      expect(owner.open_transactions).to eq(transaction_depth)
      expect(other_session_can_lock?).to be(false)
      page = Rack::Utils.parse_query(env.url.query).fetch("page").to_i
      records = MockApi::Dataset.generation_one.slice((page - 1) * 25, 25)
      [ 200, {}, { page: page, per_page: 25, total_pages: 3, total_count: 60, screenings: records }.to_json ]
    end
    allow(Screening).to receive(:transaction).and_wrap_original do |transaction, &block|
      expect(other_session_can_lock?).to be(false)
      result = transaction.call(&block)
      expect(other_session_can_lock?).to be(false)
      result
    end

    run = described_class.new(client: client).call

    expect(run).to be_succeeded
    expect(requests).to eq(3)
    expect(Screening.count).to eq(60)
    expect(other_session_can_lock?).to be(true)
  end

  it "skips immediately when another database session owns the lock" do
    expect(@other_session.exec("SELECT pg_try_advisory_lock(#{lock_key})").getvalue(0, 0)).to eq("t")
    client = instance_double(FestivalApiClient)
    expect(client).not_to receive(:screenings)
    expect(Rails.logger).to receive(:info).with(/ProgrammeSync skipped/)

    expect(described_class.new(client: client).call).to be_nil

    expect(SyncRun.count).to eq(0)
    expect(Screening.count).to eq(0)
    # Skipping must not release a lock owned by another session.
    expect(ApplicationRecord.connection.select_value("SELECT pg_try_advisory_lock(#{lock_key})")).to be(false)
  end

  it "releases the lock after an API failure while preserving failed-run tracking" do
    error = FestivalApiClient::TransientError.new("upstream unavailable")
    client = instance_double(FestivalApiClient)
    allow(client).to receive(:screenings) do
      expect(other_session_can_lock?).to be(false)
      raise error
    end

    expect { described_class.new(client: client).call }.to raise_error { |raised| expect(raised).to equal(error) }

    expect(SyncRun.sole).to be_failed
    expect(other_session_can_lock?).to be(true)
  end

  it "releases the lock after a screening transaction rolls back" do
    record = MockApi::Dataset.generation_one.first
    record["starts_at"] = "invalid timestamp"
    client = api_client do
      [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 1, screenings: [ record ] }.to_json ]
    end

    expect { described_class.new(client: client).call }.to raise_error(ActiveRecord::RecordInvalid)

    expect(SyncRun.sole).to be_failed
    expect(Screening.count).to eq(0)
    expect(other_session_can_lock?).to be(true)
  end

  it "releases the lock even when creating the SyncRun fails" do
    allow(SyncRun).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "write failed")

    expect { described_class.new(client: api_client).call }.to raise_error(ActiveRecord::StatementInvalid)
    expect(other_session_can_lock?).to be(true)
  end
end
