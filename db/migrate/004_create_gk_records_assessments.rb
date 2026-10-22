# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_assessments.
# The assessments.
# No seed data.
class CreateGkRecordsAssessments < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_assessments" do |t|
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "kind", limit: 40, null: false
      t.string "title"
      t.text "data"
      t.string "outcome"
      t.integer "user_id"
      t.text "basis"
      t.integer "supersedes_id"
      t.string "origin", limit: 20, default: "human", null: false
      t.string "origin_source_id"
      t.datetime "created_at", precision: nil, null: false
      t.text "title_translations"
      t.timestamptz "assessed_at", null: false, precision: 6
      t.index ["target_type", "target_id", "assessed_at"], name: "index_gk_records_assessments_target"
    end
  end
end
