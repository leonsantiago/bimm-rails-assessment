require "rails_helper"

RSpec.describe FestivalApiClient do
  it "requests the selected page and generation" do
    payload = api_client.screenings(page: 3, generation: 2)

    expect(payload).to include("page" => 3, "total_pages" => 3, "total_count" => 61)
    expect(payload["screenings"].last["id"]).to eq("SCR-0062")
  end

  it "reports HTTP errors" do
    expect { api_client.screenings(page: 2, fail_after: 8) }
      .to raise_error(described_class::TransientError, /HTTP 500.*page 2/)
  end

  [ Faraday::ConnectionFailed, Faraday::TimeoutError ].each do |error_class|
    it "reports #{error_class}" do
      client = api_client { raise error_class, "unavailable" }

      expect { client.screenings(page: 1) }
        .to raise_error(described_class::TransientError, /request failed.*page 1/)
    end
  end

  [ 408, 429, 502, 503, 504 ].each do |status|
    it "classifies HTTP #{status} as transient" do
      client = api_client { [ status, {}, "unavailable" ] }

      expect { client.screenings(page: 1) }.to raise_error(described_class::TransientError)
    end
  end

  [ 400, 401, 403, 404, 422 ].each do |status|
    it "does not classify HTTP #{status} as transient" do
      client = api_client { [ status, {}, "invalid request" ] }

      expect { client.screenings(page: 1) }.to raise_error do |error|
        expect(error).to be_instance_of(described_class::Error)
      end
    end
  end

  it "rejects invalid JSON" do
    client = api_client { [ 200, {}, "not JSON" ] }

    expect { client.screenings(page: 1) }.to raise_error(described_class::Error, /invalid JSON/)
  end

  [ nil, [], {}, { page: 1, per_page: 25, total_pages: 3, total_count: 60, screenings: {} },
    { page: 2, per_page: 25, total_pages: 3, total_count: 60, screenings: [] },
    { page: 1, per_page: 0, total_pages: 3, total_count: 60, screenings: [] },
    { page: 1, per_page: 25, total_pages: 1, total_count: 60, screenings: [] }
  ].each do |payload|
    it "rejects malformed response #{payload.inspect}" do
      client = api_client { [ 200, {}, JSON.generate(payload) ] }

      expect { client.screenings(page: 1) }.to raise_error(described_class::Error, /malformed pagination/)
    end
  end
end
