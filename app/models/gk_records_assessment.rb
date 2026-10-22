# frozen_string_literal: true

# An assessment on a registered target: the values as they were when someone valued the thing, the outcome, who,
# when and on what basis, kept whole. The journal keeps fields one by one; this keeps the occasion.
# Never changed and never deleted: a new assessment is made, and it says which one it supersedes.
# data is a list in the order the owner gave: [{ "key", "label", "value" }], labels frozen with the values.
class GkRecordsAssessment < ApplicationRecord
  self.table_name = 'gk_records_assessments'
  # an instant with its zone (migration 012)
  GkRecordsInstant.attributes!(self, :assessed_at)

  belongs_to :user, optional: true
  belongs_to :supersedes, class_name: 'GkRecordsAssessment', optional: true

  validates :target_type, :target_id, :kind, :assessed_at, presence: true
  validates :origin, inclusion: { in: GkRecordsNote::ORIGINS }
  validate { errors.add(:kind, :inclusion) unless GkRecords::Kinds.find(:assessment, kind) }
  validate { errors.add(:target_type, :invalid) unless target_type == 'gk_records_note' || GkRecords::Targets.find(target_type) }
  before_update { throw :abort }
  before_destroy { throw :abort }

  scope :for_target, ->(key, id) { where(target_type: key.to_s, target_id: id) }
  scope :newest_first, -> { order(assessed_at: :desc, id: :desc) }

  def values_list
    v = JSON.parse(data.presence || '[]')
    v.is_a?(Array) ? v : []
  rescue JSON::ParserError
    []
  end

  # What differs from the assessment this one supersedes: { key => the value it had then } (as it was stored, so a
  # person referred to is shown by name, GkRecords::Ref)
  def changed_from_previous
    return {} unless supersedes

    before = supersedes.values_list.to_h { |v| [v['key'], v['value']] }
    values_list.each_with_object({}) do |v, h|
      h[v['key']] = before[v['key']] if before.key?(v['key']) && before[v['key']].to_s != v['value'].to_s
    end
  end

  def title_translations_hash
    h = JSON.parse(title_translations.presence || '{}')
    h.is_a?(Hash) ? h : {}
  rescue JSON::ParserError
    {}
  end

  # The heading in the reader's language, as it was set up when the assessment was made; otherwise the
  # heading in the first language, otherwise what the kind is called
  def display_title(lang = User.current.language.presence || Setting.default_language)
    title_translations_hash[lang.to_s].presence || title.presence || GkRecords::Kinds.label(:assessment, kind)
  end

  # A person the reader may not see is null with a mark (user_hidden) (GkRecords::Visibility); so is a person referred
  # to in a value (GkRecords::Ref.api).
  # Gid, the assessment's global id (given by a list that looked them up at once, otherwise looked up here)
  def as_api_json(viewer = User.current, gid: nil)
    { id: id, gid: gid || GkRecords::Identity.for(self), target: "#{target_type}:#{target_id}", kind: kind, title: title, title_translations: title_translations_hash,
      values: GkRecords::Ref.api(values_list, viewer), outcome: outcome }
      .merge(GkRecords::Visibility.api_user(:user_id, user_id, user, viewer))
      .merge(assessed_at: assessed_at, basis: basis, supersedes_id: supersedes_id, origin: origin, origin_source_id: origin_source_id)
  end
end
