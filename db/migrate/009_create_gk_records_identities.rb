# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_records_identities.
# The global identities.
# No seed data.
class CreateGkRecordsIdentities < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_records_identities" do |t|
      t.string "target_type", limit: 60, null: false
      t.integer "target_id", null: false
      t.string "gid", limit: 36, null: false
      t.string "origin_instance", limit: 36
      t.string "owner_instance", limit: 36
      t.datetime "created_at", precision: nil, null: false
      t.index ["gid"], name: "index_gk_records_identities_on_gid", unique: true
      t.index ["origin_instance"], name: "index_gk_records_identities_on_origin_instance"
      t.index ["target_type", "target_id"], name: "index_gk_records_identities_target", unique: true
    end
  end
end
