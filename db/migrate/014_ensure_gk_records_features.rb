# frozen_string_literal: true

# Added in 1.05.000: gk_records_features, where an upgrade did not make it. The releases up to 1.03.000 had another
# migration under the number 011, so an upgrade from one of them counts 011 as done and never ran
# 011_create_gk_records_features. Here the table is made when it is missing, as 011 makes it. Nothing happens where it
# is there. No seed data.
class EnsureGkRecordsFeatures < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?('gk_records_features')

    create_table 'gk_records_features' do |t|
      t.string 'key', limit: 120, null: false
      t.boolean 'enabled', null: false
      t.integer 'updated_by_id'
      t.timestamptz 'created_at', null: false, precision: 6
      t.timestamptz 'updated_at', null: false, precision: 6
      t.index ['key'], name: 'index_gk_records_features_on_key', unique: true
    end
  end

  # Down to 0 leaves no table on either path: after an upgrade no other migration takes it away, and on a fresh
  # installation 011 finds it gone
  def down
    drop_table 'gk_records_features', if_exists: true
  end
end
