class SyncRun < ApplicationRecord
  enum :status, { running: "running", succeeded: "succeeded", failed: "failed" }, default: "running", validate: true

  validates :started_at, presence: true
  validates :screenings_created, :screenings_updated, :screenings_unchanged, :last_processed_page,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
