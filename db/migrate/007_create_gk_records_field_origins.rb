# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_field_origins.
# The fields' origins.
# No seed data.
class CreateGkRecordsFieldOrigins < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_field_origins" do |t|
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "field", limit: 60, null: false
      t.integer "reading_id", null: false
      t.string "source_id", limit: 200
      t.timestamptz "set_at", null: false, precision: 6
      t.string "source", limit: 200
      t.timestamptz "source_time", precision: 6
      t.string "value_sha256", limit: 64
      t.string "selection_key", limit: 60
      t.index ["reading_id"], name: "index_gk_records_field_origins_on_reading_id"
      t.index ["target_type", "selection_key"], name: "index_gk_records_field_origins_selection"
      t.index ["target_type", "source_id"], name: "index_gk_records_field_origins_source_id"
      t.index ["target_type", "target_id", "field"], name: "index_gk_records_field_origins_field", unique: true
    end
  end
end
