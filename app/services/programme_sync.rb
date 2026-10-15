class ProgrammeSync
  class InvalidRecord < StandardError; end

  def initialize(client: FestivalApiClient.new, generation: 1, **params)
    @client = client
    @generation = generation
    @params = params
  end

  def call
    run = SyncRun.create!(started_at: Time.current)
    counts = { screenings_created: 0, screenings_updated: 0, screenings_unchanged: 0 }
    page = 1

    begin
      loop do
        payload = @client.screenings(page: page, generation: @generation, **@params)
        payload.fetch("screenings").each do |record|
          outcome = import_screening(record)
          counts[outcome] += 1
        end
        # Only advance the checkpoint after the entire page has completed.
        run.update!(counts.merge(last_processed_page: page))
        break if page >= payload.fetch("total_pages")

        page += 1
      end
      run.update!(status: :succeeded, finished_at: Time.current)
    rescue StandardError => error
      # Persist outside the screening transaction, after its rollback has completed.
      begin
        run.update!(counts.merge(status: :failed, finished_at: Time.current,
          error_class: error.class.name, error_message: error.message))
      rescue StandardError => tracking_error
        Rails.logger.error("Could not mark SyncRun #{run.id} as failed: #{tracking_error.class}: #{tracking_error.message}")
      end
      raise error
    end

    run
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
      screening.assign_attributes(film: film, venue: venue, starts_at: record["starts_at"], status: record["status"])
      outcome = if screening.new_record?
        :screenings_created
      elsif screening.has_changes_to_save?
        :screenings_updated
      else
        :screenings_unchanged
      end
      screening.save!
      outcome
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
