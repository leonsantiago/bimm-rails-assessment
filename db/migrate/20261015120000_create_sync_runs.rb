class CreateSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_runs do |t|
      t.string :status, null: false, default: "running"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :screenings_created, null: false, default: 0
      t.integer :screenings_updated, null: false, default: 0
      t.integer :screenings_unchanged, null: false, default: 0
      t.integer :last_processed_page, null: false, default: 0
      t.text :error_class
      t.text :error_message
      t.timestamps
    end
  end
end
