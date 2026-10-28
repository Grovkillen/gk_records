# frozen_string_literal: true

# A declared function the administrator has switched on or off (GkRecords::Features). The declaration (name, help) is
# in code; this row only says what the administrator chose. Never deleted: switching back writes the row again, and
# every switch is an event.
class GkRecordsFeature < ApplicationRecord
  self.table_name = 'gk_records_features'
  # instants with their zone (migration 011)
  GkRecordsInstant.attributes!(self, :created_at, :updated_at)

  belongs_to :updated_by, class_name: 'User', optional: true

  validates :key, presence: true, uniqueness: true, length: { maximum: 120 }

  def name = GkRecords::Features.find(key)&.label || key
end
