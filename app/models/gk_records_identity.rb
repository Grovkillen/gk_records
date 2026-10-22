# frozen_string_literal: true

# A thing's global identity: one row per registered target and object.
# gid, the thing and created_at never change; origin_instance is set once (filled in when it was empty) and never
# changed after; owner_instance changes only through Identity.change_owner!, which writes the event. Never deleted.
class GkRecordsIdentity < ApplicationRecord
  self.table_name = 'gk_records_identities'

  validates :target_type, :target_id, :gid, presence: true
  validates :gid, format: { with: GkRecords::Identity::UUID }
  validates :origin_instance, :owner_instance, format: { with: GkRecords::Identity::UUID }, allow_blank: true
  validate :fixed_parts
  before_destroy { throw :abort }

  scope :for_target, ->(key, id) { where(target_type: key.to_s, target_id: id) }

  private

  def fixed_parts
    return unless persisted?

    %w[gid target_type target_id created_at].each { |f| errors.add(f, :invalid) if will_save_change_to_attribute?(f) }
    errors.add(:origin_instance, :invalid) if will_save_change_to_origin_instance? && origin_instance_in_database.present?
  end
end
