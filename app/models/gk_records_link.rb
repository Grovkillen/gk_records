# frozen_string_literal: true

# A link between any two things (registered targets, notes), with a registered kind; voided, never deleted.
# What a kind means is said where it is registered (link_semantics): a symmetric kind has no direction and one link in
# force per pair whichever end it was made from; an acyclic kind (a directed kind that says dependency) refuses the link
# that would close a circle within the kind; a kind with targets goes only to those, and one with sources only from
# those; a kind with a check only between things the owner's check lets through, and a citation's text is an optional
# place in the source, not a reason. Only links in force count, so a link made the wrong way round is voided and made
# again. Checked here, so pages, API and plugins are refused alike.
class GkRecordsLink < ApplicationRecord
  self.table_name = 'gk_records_links'
  # instants with their zone (migration 003)
  GkRecordsInstant.attributes!(self, :created_at, :voided_at)

  REASON_MAX = 500

  belongs_to :user, optional: true
  validates :source_type, :source_id, :target_type, :target_id, :kind, presence: true
  validates :reason, length: { maximum: REASON_MAX }
  validate { errors.add(:kind, :inclusion) unless kind_def }
  validate :gk_records_semantics, on: :create
  before_validation { self.reason = reason.to_s.strip.presence }
  before_destroy { throw :abort }
  # A reason given inside SystemText.as_reason that is exactly its text keeps the key and values
  before_create { GkRecords::SystemText.claim_into(self, reason) }

  scope :active, -> { where(voided_at: nil) }
  scope :touching, ->(key, id) { where(source_type: key.to_s, source_id: id).or(where(target_type: key.to_s, target_id: id)) }

  def kind_def = GkRecords::Kinds.find(:link, kind)

  def void!(user)
    update!(voided_at: Time.current, voided_by_id: user.id)
  end

  # The reason as it stood in the reader's language, and the text now when it has changed since
  def shown_reason(locale = ::I18n.locale) = GkRecords::SystemText.render(self, locale).presence
  def reason_now(locale = ::I18n.locale) = GkRecords::SystemText.changed_text(self, locale)

  # A person the reader may not see is null with a mark (user_hidden) (GkRecords::Visibility)
  def as_api_json(viewer = User.current)
    { id: id, source: "#{source_type}:#{source_id}", target: "#{target_type}:#{target_id}", kind: kind, reason: shown_reason }
      .merge(GkRecords::SystemText.api(self))
      .merge(GkRecords::Visibility.api_user(:user_id, user_id, user, viewer))
      .merge(origin: origin, created_at: created_at, voided_at: voided_at)
  end

  private

  def gk_records_semantics
    k = kind_def
    return unless k && source_id && target_id

    from = [source_type.to_s, source_id.to_i]
    to = [target_type.to_s, target_id.to_i]
    return errors.add(:base, ::I18n.t(:error_gk_records_link_self)) if from == to

    # A kind registered with targets goes only to those (either end for a symmetric kind)
    unless k.allows?(to[0]) || (k.symmetric && k.allows?(from[0]))
      return errors.add(:base, ::I18n.t(:error_gk_records_link_targets, kind: k.label, types: k.targets_label))
    end
    # And from sources only; a symmetric kind fits when one end is an allowed source and the other an allowed
    # target, whichever end it was made from (Kind#fits?)
    return errors.add(:base, ::I18n.t(:error_gk_records_link_sources, kind: k.label, types: k.sources_label)) unless k.fits?(from[0], to[0])

    # The owner's own check of the two things (Kinds.register_link check:), a source of one tracker
    if k.check && (refused = k.refusal(thing_at(*from), thing_at(*to)))
      return errors.add(:base, refused)
    end

    same = self.class.active.where(kind: kind)
    twin = same.exists?(source_type: from[0], source_id: from[1], target_type: to[0], target_id: to[1])
    twin ||= k.symmetric && same.exists?(source_type: to[0], source_id: to[1], target_type: from[0], target_id: from[1])
    return errors.add(:base, ::I18n.t(:error_gk_records_link_twice)) if twin

    # Not for a citation, whose text is an optional place in the source (Kinds.register_link citation:), not a reason
    errors.add(:base, ::I18n.t(:error_gk_records_link_reason)) if k.manual && !k.citation && reason.blank? && GkRecords::Reasons.required?('records.link_manual')
    return unless k.acyclic

    path = GkRecords::Links.path(kind, to, from)
    return unless path

    chain = ([from] + path).map { |key, id| GkRecords::Links.ref_label(key, id) }.join(' → ')
    errors.add(:base, ::I18n.t(:error_gk_records_link_cycle, chain: chain))
  end

  # The object at one end for a kind's check, whoever the reader is; nil for a note or a thing that is gone
  def thing_at(key, id)
    t = GkRecords::Targets.find(key)
    t&.model_class&.find_by(id: id)
  end
end
