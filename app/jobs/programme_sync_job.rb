class ProgrammeSyncJob < ApplicationJob
  queue_as :default

  # Active Job owns retries; Sidekiq must not add another retry cycle.
  sidekiq_options retry: false
  retry_on FestivalApiClient::TransientError, wait: 30.seconds, attempts: 3, jitter: 0

  def perform(generation: 1)
    ProgrammeSync.new(generation: generation).call
  end
end
