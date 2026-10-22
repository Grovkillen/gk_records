# frozen_string_literal: true

# A note on a registered target. Never edited after it is saved: a correction is a new note with the link
# "corrects", and a note is voided (with a reason, itself a note on the note), never deleted.
class GkRecordsNote < ApplicationRecord
  self.table_name = 'gk_records_notes'
  # instants with their zone (migration 012)
  GkRecordsInstant.attributes!(self, :created_at, :voided_at)

  ORIGINS = %w[human system import agent].freeze

  belongs_to :user, optional: true
  belongs_to :parent, class_name: 'GkRecordsNote', optional: true
  belongs_to :voided_by, class_name: 'User', optional: true
  belongs_to :void_reason, class_name: 'GkRecordsNote', foreign_key: :void_reason_note_id, optional: true
  has_many :replies, class_name: 'GkRecordsNote', foreign_key: :parent_id

  validates :target_type, :target_id, :kind, :body, presence: true
  validates :origin, inclusion: { in: ORIGINS }
  validate :kind_registered, :target_registered, :within_max_length
  validate { errors.add(:target_type, :invalid) if target_type == 'issue' } # an issue's notes are its journal
  before_update :only_voiding
  # A body written inside SystemText.as_reason that is exactly its text keeps the key and values
  before_create { GkRecords::SystemText.claim_into(self, body) }

  scope :for_target, ->(key, id) { where(target_type: key.to_s, target_id: id) }

  def self.max_length
    n = Setting.plugin_gk_records['note_max_length'].to_i
    n.positive? ? n : 4000
  end

  def voided? = voided_at.present?

  # Without a reason (the place records.note_void optional or off) no reason note is made
  def void!(user, reason)
    reason_note = reason.present? ? GkRecordsNote.create!(target_type: 'gk_records_note', target_id: id, kind: 'reason', body: reason, user_id: user.id) : nil
    update!(voided_at: Time.current, voided_by_id: user.id, void_reason_note_id: reason_note&.id)
  end

  # Notes that correct this one (link corrects from the new note to this)
  def corrected_by
    ids = GkRecordsLink.active.where(kind: 'corrects', target_type: 'gk_records_note', target_id: id, source_type: 'gk_records_note').pluck(:source_id)
    GkRecordsNote.where(id: ids).order(:created_at, :id)
  end

  def corrects
    ids = GkRecordsLink.active.where(kind: 'corrects', source_type: 'gk_records_note', source_id: id, target_type: 'gk_records_note').pluck(:target_id)
    GkRecordsNote.where(id: ids)
  end

  # The body as it stood in the reader's language (a system text kept as a key; a person's text as written), and the
  # text now when it has changed since (nil otherwise)
  def shown_body(locale = ::I18n.locale) = GkRecords::SystemText.render(self, locale)
  def body_now(locale = ::I18n.locale) = GkRecords::SystemText.changed_text(self, locale)

  # A person the reader may not see is null with a mark (user_hidden, voided_by_hidden) (GkRecords::Visibility)
  # Body in the reader's language; a system text adds text_key, text_values, text_stored and text_now
  def as_api_json(viewer = User.current)
    vis = GkRecords::Visibility
    { id: id, target: "#{target_type}:#{target_id}", kind: kind }.merge(vis.api_user(:user_id, user_id, user, viewer))
      .merge(body: shown_body, parent_id: parent_id, origin: origin, created_at: created_at, voided_at: voided_at)
      .merge(vis.api_user(:voided_by_id, voided_by_id, voided_by, viewer))
      .merge(GkRecords::SystemText.api(self))
      .merge(void_reason: void_reason&.shown_body, corrects: corrects.pluck(:id), corrected_by: corrected_by.pluck(:id))
  end

  private

  def kind_registered
    errors.add(:kind, :inclusion) unless GkRecords::Kinds.find(:note, kind)
  end

  # A note on a note (the reason for voiding) is allowed; everything else needs a registered target
  def target_registered
    return if target_type == 'gk_records_note'

    errors.add(:base, ::I18n.t(:error_gk_records_target)) unless GkRecords::Targets.find(target_type)
  end

  def within_max_length
    errors.add(:body, :too_long, count: self.class.max_length) if body.to_s.length > self.class.max_length
  end

  def only_voiding
    allowed = %w[voided_at voided_by_id void_reason_note_id]
    throw :abort unless (changed - allowed).empty?
  end
end
