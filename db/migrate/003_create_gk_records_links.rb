# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_links.
# The links.
# No seed data.
class CreateGkRecordsLinks < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_links" do |t|
      t.string "source_type", limit: 60, null: false
      t.integer "source_id", null: false
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "kind", limit: 40, null: false
      t.integer "user_id"
      t.string "origin", limit: 20, default: "human", null: false
      t.integer "voided_by_id"
      t.text "reason"
      t.string "text_key", limit: 200
      t.text "text_values"
      t.timestamptz "created_at", null: false, precision: 6
      t.timestamptz "voided_at", precision: 6
      t.index ["source_type", "source_id"], name: "index_gk_records_links_source"
      t.index ["target_type", "target_id", "created_at"], name: "index_gk_records_links_target"
    end
  end
end
