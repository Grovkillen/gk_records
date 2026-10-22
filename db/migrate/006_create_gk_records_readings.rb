# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_readings.
# The readings.
# No seed data.
class CreateGkRecordsReadings < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_readings" do |t|
      t.string "source_label", limit: 200, null: false
      t.string "source_url"
      t.string "route", limit: 20, default: "file", null: false
      t.string "format", limit: 20
      t.string "source_ref", limit: 200
      t.integer "user_id"
      t.string "account", limit: 100
      t.string "mode", limit: 20, default: "once", null: false
      t.integer "rows"
      t.text "counts_json"
      t.string "target_type", limit: 60
      t.text "manifest_json"
      t.boolean "made_afterwards", default: false, null: false
      t.integer "origin_reading_id"
      t.datetime "created_at", precision: nil, null: false
      t.timestamptz "source_time", precision: 6
      t.timestamptz "read_at", precision: 6
      t.text "files_json"
      t.string "mapping", limit: 80
      t.timestamptz "retrieved_at", precision: 6
      t.text "selection_json"
      t.index ["source_label", "read_at"], name: "index_gk_records_readings_source"
      t.index ["target_type"], name: "index_gk_records_readings_on_target_type"
    end
  end
end
