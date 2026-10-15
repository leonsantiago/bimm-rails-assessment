class ProgrammeSync
  class InvalidRecord < StandardError; end

  def initialize(client: FestivalApiClient.new, generation: 1, **params)
    @client = client
    @generation = generation
    @params = params
  end

  def call
    page = 1
    loop do
      payload = @client.screenings(page: page, generation: @generation, **@params)
      payload.fetch("screenings").each { |record| import_screening(record) }
      break if page >= payload.fetch("total_pages")

      page += 1
    end
  end

  private

  def import_screening(record)
    validate_record!(record)

    Screening.transaction do
      film = Film.find_or_initialize_by(external_id: record["film"]["id"])
      film.update!(record["film"].slice("title", "synopsis", "runtime", "year"))

      venue = Venue.find_or_initialize_by(external_id: record["venue"]["id"])
      venue.update!(record["venue"].slice("name", "address", "capacity"))

      screening = Screening.find_or_initialize_by(external_id: record["id"])
      screening.update!(film: film, venue: venue, starts_at: record["starts_at"], status: record["status"])
    end
  end

  def validate_record!(record)
    valid = record.is_a?(Hash) && external_id?(record["id"]) &&
      record["starts_at"].is_a?(String) && record["starts_at"].present? &&
      Screening.statuses.key?(record["status"]) &&
      record["film"].is_a?(Hash) && external_id?(record["film"]["id"]) &&
      record["film"]["title"].is_a?(String) && record["film"]["title"].present? &&
      record["venue"].is_a?(Hash) && external_id?(record["venue"]["id"]) &&
      record["venue"]["name"].is_a?(String) && record["venue"]["name"].present?

    raise InvalidRecord, "Festival API returned a malformed screening: #{record.inspect}" unless valid
  end

  def external_id?(value)
    value.is_a?(String) && value.present?
  end
end
