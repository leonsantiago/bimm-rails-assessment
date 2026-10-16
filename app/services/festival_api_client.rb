require "json"

class FestivalApiClient
  class Error < StandardError; end
  class TransientError < Error; end

  def initialize(base_url: ENV.fetch("FESTIVAL_API_URL", "http://localhost:3000"), connection: nil)
    @connection = connection || Faraday.new(url: base_url) do |http|
      http.options.open_timeout = 3
      http.options.timeout = 10
    end
  end

  def screenings(page:, generation: 1, **params)
    response = @connection.get("/mock_api/screenings", params.merge(page: page, generation: generation))
    unless response.success?
      error_class = [ 408, 429 ].include?(response.status) || (500..599).cover?(response.status) ? TransientError : Error
      raise error_class, "Festival API returned HTTP #{response.status} on page #{page}"
    end

    payload = JSON.parse(response.body)
    validate_page!(payload, page)
    payload
  rescue JSON::ParserError
    raise Error, "Festival API returned invalid JSON on page #{page}"
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => error
    raise TransientError, "Festival API request failed on page #{page}: #{error.message}"
  rescue Faraday::Error => error
    raise Error, "Festival API request failed on page #{page}: #{error.message}"
  end

  private

  def validate_page!(payload, page)
    valid = payload.is_a?(Hash) &&
      payload["page"] == page &&
      payload["per_page"].is_a?(Integer) && payload["per_page"].positive? &&
      payload["total_pages"].is_a?(Integer) && payload["total_pages"] >= 0 &&
      payload["total_count"].is_a?(Integer) && payload["total_count"] >= 0 &&
      payload["screenings"].is_a?(Array)

    if valid
      expected_pages = (payload["total_count"].to_f / payload["per_page"]).ceil
      valid = payload["total_pages"] == expected_pages &&
        page <= [ expected_pages, 1 ].max &&
        payload["screenings"].size <= payload["per_page"]
    end

    raise Error, "Festival API returned malformed pagination on page #{page}" unless valid
  end
end
