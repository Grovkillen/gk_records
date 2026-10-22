# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_verifications.
# The verification statuses.
# No seed data.
class CreateGkRecordsVerifications < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_verifications" do |t|
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "status", limit: 20, null: false
      t.integer "set_by_id"
      t.text "reason"
      t.timestamptz "set_at", null: false, precision: 6
      t.index ["target_type", "target_id"], name: "index_gk_records_verifications_target", unique: true
    end
  end
end
