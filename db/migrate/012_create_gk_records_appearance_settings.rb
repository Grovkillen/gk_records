# frozen_string_literal: true

# Added in 1.05.000: gk_records_appearance_settings.
# The levels and values of the appearance settings (GkRecords::AppearanceSettings): one row per setting for the
# instance (user_id 0), and one row per setting for each person who chose about an optional one (user_id the person).
# The key * of a person is the person's "Like Redmine for me".
# No seed data.
class CreateGkRecordsAppearanceSettings < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_appearance_settings" do |t|
      t.string "key", limit: 120, null: false
      t.integer "user_id", default: 0, null: false
      t.string "mode", limit: 10
      t.text "values_json"
      t.integer "updated_by_id"
      t.timestamptz "created_at", null: false, precision: 6
      t.timestamptz "updated_at", null: false, precision: 6
      t.index ["key", "user_id"], name: "index_gk_records_appearance_settings_on_key_user", unique: true
      t.index ["user_id"], name: "index_gk_records_appearance_settings_on_user"
    end
  end
end
