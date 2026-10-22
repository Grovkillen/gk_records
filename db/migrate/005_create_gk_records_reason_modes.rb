# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_reason_modes.
# The reasons' modes.
# No seed data.
class CreateGkRecordsReasonModes < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_reason_modes" do |t|
      t.string "key", limit: 120, null: false
      t.string "mode", limit: 20, null: false
      t.integer "updated_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_records_reason_modes_on_key", unique: true
    end
  end
end
