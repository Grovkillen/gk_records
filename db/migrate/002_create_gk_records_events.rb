# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_events.
# The events.
# No seed data.
class CreateGkRecordsEvents < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_events" do |t|
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "kind", limit: 40, null: false
      t.text "details"
      t.integer "user_id"
      t.integer "acting_user_id"
      t.integer "reason_note_id"
      t.string "origin", limit: 20, default: "human", null: false
      t.string "origin_source_id"
      t.integer "project_id"
      t.string "reason_key", limit: 120
      t.string "text_key", limit: 200
      t.text "text_values"
      t.timestamptz "created_at", null: false, precision: 6
      t.index ["kind", "project_id"], name: "index_gk_records_events_kind_project"
      t.index ["reason_key", "user_id"], name: "index_gk_records_events_reason_key"
      t.index ["target_type", "target_id", "created_at"], name: "index_gk_records_events_target"
    end
  end
end
