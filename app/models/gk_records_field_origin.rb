# frozen_string_literal: true

# Which reading last set a field of an object: target (records' key and id), the field, the reading and the source's
# id for the post, the source behind the value and when it said it, and the SHA-256 of the value as it was set (never
# the value). One row per field; a new reading moves it (Readings.set!), the old reading stays.
class GkRecordsFieldOrigin < ApplicationRecord
  self.table_name = 'gk_records_field_origins'
  # instants with their zone
  GkRecordsInstant.attributes!(self, :set_at, :source_time)

  belongs_to :reading, class_name: 'GkRecordsReading'

  validates :target_type, :target_id, :field, :reading_id, :set_at, presence: true
  validates :source, length: { maximum: 200 }
  validates :value_sha256, format: { with: /\A\h{64}\z/ }, allow_nil: true

  scope :for_target, ->(key, id) { where(target_type: key.to_s, target_id: id) }

  def target
    t = GkRecords::Targets.find(target_type)
    t && t.model_class.find_by(id: target_id)
  end
end
