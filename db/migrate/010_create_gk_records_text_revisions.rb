# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_text_revisions.
# The system texts' revisions.
# No seed data.
class CreateGkRecordsTextRevisions < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_text_revisions" do |t|
      t.string "key", limit: 200, null: false
      t.string "locale", limit: 10, null: false
      t.text "body", null: false
      t.string "sha256", limit: 64, null: false
      t.timestamptz "valid_from", null: false, precision: 6
      t.timestamptz "created_at", null: false, precision: 6
      t.index ["key", "locale", "valid_from"], name: "index_gk_records_text_revisions_cell"
    end
  end
end
