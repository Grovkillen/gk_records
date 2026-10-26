# frozen_string_literal: true

# An event on a registered target, written by the owner plugin (GkRecords::Events.write). Never changed,
# never thinned (P1).
class GkRecordsEvent < ApplicationRecord
  self.table_name = 'gk_records_events'
  # created_at is an instant with its zone (migration 011), so the order holds in the hour that comes twice
  GkRecordsInstant.attributes!(self, :created_at)

  belongs_to :user, optional: true
  belongs_to :acting_user, class_name: 'User', optional: true
  belongs_to :reason_note, class_name: 'GkRecordsNote', optional: true

  validates :target_type, :target_id, :kind, presence: true
  before_update { throw :abort }
  before_destroy { throw :abort }

  after_create_commit { GkRecords::Events.notify(self) }

  scope :for_target, ->(key, id) { where(target_type: key.to_s, target_id: id) }

  # An event of a kind that asks a permission (Kinds.register_event permission:, an export or a print) is shown
  # only to those who have it in the event's project, or anywhere when the event has no project; every other kind
  # as before. Administrators see all. Every list of events asks here. The projects are asked with an OAuth token's
  # scopes (GkRecords::ApiScope), as core's own checks do.
  scope :readable_by, lambda { |user = User.current|
    restricted = GkRecords::Kinds.of(:event).select(&:permission)
    next all if user.admin? || restricted.empty?

    t = table_name
    conds = [sanitize_sql_array(["#{t}.kind NOT IN (?)", restricted.map(&:key)])]
    restricted.group_by(&:permission).each do |perm, kinds|
      projects = Project.where(GkRecords::ApiScope.project_condition(user, perm)).select(:id).to_sql
      global = user.allowed_to_globally?(perm) ? " OR #{t}.project_id IS NULL" : ''
      conds << sanitize_sql_array(["(#{t}.kind IN (?) AND (#{t}.project_id IN (#{projects})#{global}))", kinds.map(&:key)])
    end
    where(conds.join(' OR '))
  }

  # The event log a reader may open (1.01.000), newest first, or nil when the reader may not open it at all:
  # project: the project's tab (Se händelser in the project; its subprojects where they have it too, when core shows
  # subprojects' issues); without a project the log under Administration: everything for an administrator, else the
  # events of the projects where the reader has Se händelser, never those without a project. The page, its CSV and the
  # scenario checks ask here, so they never differ.
  def self.log_for(user, project: nil)
    perm = :gk_records_view_events
    scope = readable_by(user).includes(:user, :reason_note).order(created_at: :desc, id: :desc)
    if project
      return nil unless user.allowed_to?(perm, project)

      base = Setting.display_subprojects_issues? ? project.self_and_descendants : Project.where(id: project.id)
      return scope.where(project_id: Project.where(id: base.select(:id)).where(GkRecords::ApiScope.project_condition(user, perm)).select(:id))
    end
    return scope if user.admin?

    ids = Project.where(GkRecords::ApiScope.project_condition(user, perm)).select(:id)
    ids.exists? ? scope.where(project_id: ids) : nil
  end

  def details_hash
    JSON.parse(details.presence || '{}')
  rescue JSON::ParserError
    {}
  end

  def target
    t = GkRecords::Targets.find(target_type)
    t && t.model_class.find_by(id: target_id)
  end

  # Query columns (GkRecordsEventQuery); the view gives them links and tags, CSV and JSON get these texts
  # A target the reader may not see is not named either (a person registered as a target is named by her name)
  def target_label
    t = target
    return "#{target_type}:#{target_id}" unless t

    GkRecords::Targets.visible?(t) ? GkRecords::Targets.label(t) : ::I18n.t(:text_gk_records_hidden_thing)
  end

  # The reason kept in the details (Events.write on a target whose notes are refused, such as an issue): only
  # when there is no reason note and the value is a plain text, never a change [before, after]
  def details_reason
    return nil if reason_note_id

    r = details_hash['reason']
    r.is_a?(String) && r.present? ? r : nil
  end

  # The details without such a reason, for the changes column.
  # A field the kind declared private (Kinds.register_event private_fields:) is left out for a viewer who may not see
  # the target, and for everyone while the target is voided (hidden_fields says which); the stored details never change.
  def change_details(viewer = User.current)
    d = details_reason ? details_hash.except('reason') : details_hash
    hidden = hidden_fields(viewer)
    hidden.empty? ? d : d.except(*hidden)
  end

  # The private fields present in the details that the viewer is not shown (none when the kind declares none)
  def hidden_fields(viewer = User.current)
    own = GkRecords::Kinds.private_fields(kind)
    return [] if own.empty?

    present = own & details_hash.keys
    return [] if present.empty?

    t = target
    shown = t && !GkRecords::Targets.voided?(t) && GkRecords::Targets.visible?(t, viewer)
    shown ? [] : present
  end

  # A person in the details is a reference (GkRecords::Ref) and is said by name only to a viewer who may see her;
  # a private field the viewer may not see is named with the text for a hidden value
  def changes_text(viewer = User.current)
    d = change_details(viewer)
    found = GkRecords::Ref.principals(d)
    say = ->(v) { GkRecords::Ref.text(v, viewer, found) }
    shown = d.map { |f, c| c.is_a?(Array) && c.size == 2 ? "#{f}: #{say.call(c[0])} > #{say.call(c[1])}" : "#{f}: #{say.call(c)}" }
    (shown + hidden_fields(viewer).map { |f| "#{f}: #{::I18n.t(:text_gk_records_hidden_value)}" }).join('; ')
  end

  # In the reader's language as it stood (a system text kept as a key on the reason note or, on an issue, on the
  # event); reason_now the text now when it has changed since (nil otherwise)
  def reason_text = (reason_note ? reason_note.shown_body : GkRecords::SystemText.render(self)).to_s
  def reason_now = reason_note ? reason_note.body_now : GkRecords::SystemText.changed_text(self)

  # A system reason's key, values, stored text and text now as reason_text_key, reason_text_values,
  # reason_text_stored and reason_text_now; empty for a person's reason
  def reason_api = GkRecords::SystemText.api(reason_note || self).transform_keys { |k| :"reason_#{k}" }
  def kind_label = GkRecords::Kinds.label(:event, kind)

  # A person the reader may not see is null with a mark (user_hidden, acting_user_hidden), never an id
  # (GkRecords::Visibility); so is the author of the reason note, and so is a person referred to in the details ({
  # "principal" => null, "hidden" => true }; one shown is { "principal" => id, "name" => name }).
  # A private field the viewer may not see is null, named in details_hidden
  def as_api_json(viewer = User.current)
    vis = GkRecords::Visibility
    hidden = hidden_fields(viewer)
    d = hidden.empty? ? details_hash : details_hash.merge(hidden.index_with(nil))
    { id: id, target: "#{target_type}:#{target_id}", kind: kind, details: GkRecords::Ref.api(d, viewer) }
      .merge(hidden.empty? ? {} : { details_hidden: hidden })
      .merge(vis.api_user(:user_id, user_id, user, viewer))
      .merge(vis.api_user(:acting_user_id, acting_user_id, acting_user, viewer))
      .merge(reason: reason_text.presence, origin: origin, created_at: created_at)
      .merge(reason_api)
  end
end
