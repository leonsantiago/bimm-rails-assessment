module FestivalApiHelpers
  def api_client(&response)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/mock_api/screenings") do |env|
        if response
          response.call(env)
        else
          result = Rack::MockRequest.new(Rails.application).get(env.url.request_uri, "HTTP_HOST" => "www.example.com")
          [ result.status, result.headers, result.body ]
        end
      end
    end
    connection = Faraday.new { |http| http.adapter :test, stubs }
    FestivalApiClient.new(connection: connection)
  end
end

RSpec.configure do |config|
  config.include FestivalApiHelpers
end
