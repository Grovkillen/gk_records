# frozen_string_literal: true

# Added in 1.04.000: gk_records_features.
# The administrator's switches for the declared functions (GkRecords::Features).
# No seed data.
class CreateGkRecordsFeatures < ActiveRecord::Migration[6.1]
  def up
    create_table "gk_records_features" do |t|
      t.string "key", limit: 120, null: false
      t.boolean "enabled", null: false
      t.integer "updated_by_id"
      t.timestamptz "created_at", null: false, precision: 6
      t.timestamptz "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_records_features_on_key", unique: true
    end
  end

  # 014 has already taken the table away when the migrations go down to 0
  def down
    drop_table "gk_records_features", if_exists: true
  end
end
