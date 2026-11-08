# frozen_string_literal: true

# The level and values an administrator set for an appearance setting (user_id 0), or a person's own choice about an
# optional one (user_id the person) (GkRecords::AppearanceSettings). The declaration (name, help, levels, values) is in
# code; this row only says what was chosen. The instance's row with the key start holds the installation's start
# choice (AppearanceSettings.start!). Never deleted: a change writes the row again, and every change is an event
# on it.
class GkRecordsAppearanceSetting < ApplicationRecord
  self.table_name = 'gk_records_appearance_settings'
  # instants with their zone (migration 012)
  GkRecordsInstant.attributes!(self, :created_at, :updated_at)

  INSTANCE = 0

  belongs_to :updated_by, class_name: 'User', optional: true

  validates :key, presence: true, length: { maximum: 120 }, uniqueness: { scope: :user_id }
  validates :mode, length: { maximum: 10 }

  scope :instance, -> { where(user_id: INSTANCE) }

  def person? = user_id.to_i != INSTANCE
  def person = person? ? User.find_by(id: user_id) : nil

  def values_hash
    v = values_json.present? ? JSON.parse(values_json) : {}
    v.is_a?(Hash) ? v : {}
  rescue JSON::ParserError
    {}
  end

  def values_hash=(hash)
    self.values_json = hash.present? ? hash.to_json : nil
  end

  def name
    return ::I18n.t(:label_gk_records_appearance_start) if key == GkRecords::AppearanceSettings::START && !person?

    row = GkRecords::AppearanceSettings.find(key)
    label = row ? row.label : key
    person? ? "#{label} (#{person&.name || user_id})" : label
  end
end
