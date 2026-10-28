# frozen_string_literal: true

module GkRecords
  # A registered target: a model whose objects may have notes, events and links. The owner plugin says who
  # may see and write (visible, editable), how the object is named (label) and where it lives (url).
  # Issues are targets for events only (written by workflow_rules, so triggers can listen); their notes and
  # history are core's Journal, so a note on an issue is refused (GkRecordsNote).
  # linkable: who may add and void links on the object (links_view); without it the same as editable. An issue
  # is never editable here (no notes on issues) but may be linked by whoever may edit the issue.
  # voided: optional, ->(obj) { true when the owner has voided the thing }; a voided thing's private detail fields
  # (Kinds.register_event private_fields:) are shown to no one.
  # Without it a thing is never voided here.
  Target = Struct.new(:key, :model, :visible, :editable, :label, :url, :linkable, :voided, keyword_init: true) do
    def model_class = model.to_s.constantize
  end

  # A registered kind: scope note, event or link; label_key is the owner's locale key
  # target: for event kinds, the target key the event is written on (the choice list in triggers)
  # For link kinds (links_view): attention (the owner says a link of this kind is shown as a mark on the thing,
  # not only counted), manual (a person may make one by hand on the links page; otherwise only the owner plugin
  # makes them; a link by hand needs a short reason) and reverse_label_key (what the kind is called seen from the
  # other end: "corrected by").
  # What a link kind means (link_semantics): symmetric (no direction: the two things belong together, shown the
  # same from both ends, one link in force per pair) or directed, and acyclic (a directed kind that says
  # dependency: the link that would close a circle within the kind is refused). Analysis follows directed kinds
  # only, and may trust that an acyclic kind has no circles.
  # person_fields: for event kinds, the names of the detail fields that hold people, whatever the form (a principal, a
  # thing of a registered kind such as a register person, a list or a change of them), so other plugins may ask
  # (Kinds.person_fields, Kinds.person_field?) without reading the values. Always a list of strings, empty when none is
  # declared.
  # targets: for link kinds, the target keys the link may go to (%w[organization]); nil when any thing may be at the
  # other end. A symmetric kind has no direction, so either end may be the allowed one. Checked by GkRecordsLink, and
  # the box Lägg till koppling offers only these.
  # sources: for link kinds, the target keys the link may go from, as targets says where it may go; nil when any thing
  # may be the source. A directed kind needs an allowed source and an allowed target in that order (fits?); a symmetric
  # kind has no direction, so it fits when one end is an allowed source and the other an allowed target, whichever end
  # it was made from. The box Lägg till koppling offers a kind only on a thing that may be one end of it (offered_on?).
  # private_fields: for event kinds, the detail fields whose values belong to the target: shown (pages, CSV, REST) only
  # to a reader who may see the event's target, and to no one while the target is voided (Target voided:). The values
  # are stored as written; only what is shown is held back.
  # check: for link kinds, the owner's own test of the two things beyond their sorts, ->(source_obj, target_obj) { nil
  # when the link fits, otherwise a message (or true for records' own) }: a link to an issue of one tracker only. Asked
  # by GkRecordsLink after targets and sources, and by the box Lägg till koppling, which offers only what passes. Either
  # object may be nil (a note).
  # citation: for link kinds, the link says where the facts of its source come from: its text is a place in the thing at
  # the other end ("s. 14", "avsnitt 3.2"), optional and never a reason, and the source's page may show the things it
  # cites beside its own source text (Links.citations, gk_records_citations).
  # names and scale: an assessment kind that is data (AssessmentKinds) has its names per language ({ 'sv' => 'Dubbla
  # användningsområden', 'en' => 'Dual use' }) instead of a locale key, and may have a scale, the outcomes it is valued
  # on ([{ 'key' => 'possible', 'names' => {... } }]); nil for the kinds plugins register.
  Kind = Struct.new(:scope, :key, :plugin, :label_key, :symmetric, :acyclic, :target, :attention, :manual, :reverse_label_key,
                    :person_fields, :permission, :targets, :sources, :private_fields, :check, :citation, :names, :scale,
                    keyword_init: true) do
    def label = names.present? ? Kinds.name_in(names) : ::I18n.t(label_key, default: key.to_s.tr('_', ' ').capitalize)

    # The text of one of the scale's values in the reader's language (lang: another one), or nil when it has no such value
    def scale_label(value, lang = nil)
      v = Array(scale).detect { |s| s['key'].to_s == value.to_s }
      v ? Kinds.name_in(v['names'], lang).presence || v['key'].to_s : nil
    end
    def reverse_label = reverse_label_key ? ::I18n.t(reverse_label_key, default: label) : nil
    def allows?(target_key) = targets.nil? || targets.include?(target_key.to_s)
    def allows_source?(source_key) = sources.nil? || sources.include?(source_key.to_s)
    def targets_label = Array(targets).map { |k| Targets.thing_label(k) }.join(', ')
    def sources_label = Array(sources).map { |k| Targets.thing_label(k) }.join(', ')

    # Whether a link of this kind may go from a thing of sort from to one of sort to (both lists at once)
    def fits?(from, to) = (allows_source?(from) && allows?(to)) || (symmetric ? (allows_source?(to) && allows?(from)) : false)

    # Whether a thing of this sort may be one end of the kind at all (the box offers the kind there only then)
    def offered_on?(key) = allows_source?(key) || (symmetric ? allows?(key) : false)

    # Why the owner's check refuses a link from one thing to another, or nil when it fits (or there is no check). A
    # check that fails is a refusal, never a silent pass.
    def refusal(from_obj, to_obj)
      return nil unless check

      r = check.call(from_obj, to_obj)
      r.is_a?(String) ? r : (r ? ::I18n.t(:error_gk_records_link_check, kind: label) : nil)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] check of link kind #{key} failed: #{e.class} #{e.message}")
      ::I18n.t(:error_gk_records_link_check, kind: label)
    end
  end

  module Targets
    module_function

    def all = (@all ||= {})

    # A registered target's model gets the identity hook (Identity.install), so every new thing of it has a global id;
    # a model that cannot take it yet is tried again later
    def register(key, model:, visible:, editable:, label:, url:, linkable: nil, voided: nil)
      t = all[key.to_s] = Target.new(key: key.to_s, model: model.to_s, visible: visible, editable: editable, label: label, url: url,
                                     linkable: linkable, voided: voided)
      Identity.install(t.model) if defined?(Identity) && Identity.respond_to?(:install)
      registered_from[key.to_s] = caller_locations(1, 1).first&.path.to_s
      t
    end

    def find(key) = all[key.to_s]

    # Where each target was registered from (the file), so the settings page can say which plugin owns it
    def registered_from = (@registered_from ||= {})

    # The plugin that registered a target (a Redmine::Plugin), or nil when it is not found among the plugins. The
    # file's folders are matched against the plugins' ids (a plugin's folder is named by its id), not against
    # Plugin#directory, since a plugin may be linked in from elsewhere (a junction to a build) and the loaded file then
    # has the other path.
    def owner(key)
      folders = registered_from[key.to_s].to_s.tr('\\', '/').downcase.split('/')
      return nil if folders.empty?

      Redmine::Plugin.all.detect { |p| folders.include?(p.id.to_s.downcase) }
    end

    def for_object(obj)
      all.values.detect { |t| obj.class.name == t.model }
    end

    # "key:id" -> [target, object] or nil
    def resolve(ref)
      key, id = ref.to_s.split(':', 2)
      t = find(key)
      obj = t && t.model_class.find_by(id: id.to_i)
      obj ? [t, obj] : nil
    end

    def ref(obj)
      t = for_object(obj)
      t ? "#{t.key}:#{obj.id}" : nil
    end

    def visible?(obj, user = User.current)
      t = for_object(obj)
      t ? !!t.visible.call(obj, user) : false
    end

    def editable?(obj, user = User.current)
      t = for_object(obj)
      t ? !!t.editable.call(obj, user) : false
    end

    def linkable?(obj, user = User.current)
      t = for_object(obj)
      return false unless t

      t.linkable ? !!t.linkable.call(obj, user) : !!t.editable.call(obj, user)
    end

    # Whether the owner says the thing is voided (Target voided:); never without it
    def voided?(obj)
      t = for_object(obj)
      t&.voided ? !!t.voided.call(obj) : false
    end

    def label(obj)
      t = for_object(obj)
      t ? t.label.call(obj).to_s : obj.to_s
    end

    # What sort of thing a target is, in the reader's language (core's own word where it has one): "Ärende", "Grupp"
    def thing_label(key)
      return ::I18n.t(:label_gk_records_note) if key.to_s == 'gk_records_note'

      t = find(key)
      t ? ::I18n.t("label_#{t.model.underscore}", default: key.to_s.tr('_', ' ').capitalize) : key.to_s
    end

    def url(obj)
      t = for_object(obj)
      t&.url&.call(obj)
    end
  end

  module Kinds
    module_function

    def all = (@all ||= {})

    def register(scope, key, plugin:, label_key:, symmetric: false, acyclic: false, target: nil, attention: false, manual: false,
                 reverse_label_key: nil, person_fields: nil, permission: nil, targets: nil, sources: nil, private_fields: nil,
                 check: nil, citation: false)
      raise ArgumentError, "link kind #{key}: a symmetric kind has no direction and cannot be acyclic" if symmetric && acyclic
      raise ArgumentError, "#{scope} kind #{key}: check belongs to link kinds" if check && scope.to_s != 'link'
      raise ArgumentError, "#{scope} kind #{key}: citation belongs to link kinds" if citation && scope.to_s != 'link'
      raise ArgumentError, "link kind #{key}: a citation has a direction (from the thing to what it cites)" if citation && symmetric

      fields = Array(person_fields).map(&:to_s).reject(&:empty?).uniq.freeze
      raise ArgumentError, "#{scope} kind #{key}: person_fields belong to event kinds" if fields.any? && scope.to_s != 'event'

      bound = Array(private_fields).map(&:to_s).reject(&:empty?).uniq.freeze
      raise ArgumentError, "#{scope} kind #{key}: private_fields belong to event kinds" if bound.any? && scope.to_s != 'event'

      allowed = targets.nil? ? nil : Array(targets).map(&:to_s).reject(&:empty?).uniq.freeze.presence
      raise ArgumentError, "#{scope} kind #{key}: targets belong to link kinds" if allowed && scope.to_s != 'link'

      from = sources.nil? ? nil : Array(sources).map(&:to_s).reject(&:empty?).uniq.freeze.presence
      raise ArgumentError, "#{scope} kind #{key}: sources belong to link kinds" if from && scope.to_s != 'link'

      all["#{scope}:#{key}"] = Kind.new(scope: scope.to_s, key: key.to_s, plugin: plugin.to_s, label_key: label_key, symmetric: symmetric,
                                        acyclic: acyclic, target: target&.to_s, attention: attention, manual: manual,
                                        reverse_label_key: reverse_label_key, person_fields: fields, permission: permission&.to_sym,
                                        targets: allowed, sources: from, private_fields: bound, check: check, citation: citation ? true : false)
    end

    # Whether register_link takes targets:, so an owner plugin may ask before it passes them
    def link_targets? = true
    # Whether register_link takes sources: and register_event private_fields:, likewise
    def link_sources? = true
    def private_fields? = true
    # Whether register_link takes check: and citation:, likewise
    def link_checks? = true
    def link_citations? = true

    def register_note(key, **opts) = register(:note, key, **opts)
    def register_event(key, **opts) = register(:event, key, **opts)
    def register_link(key, **opts) = register(:link, key, **opts)
    def register_assessment(key, **opts) = register(:assessment, key, **opts)

    # The assessment kinds that are data (AssessmentKinds) are found and listed beside the registered ones; a registered
    # kind wins over data with the same key
    def find(scope, key) = all["#{scope}:#{key}"] || (scope.to_s == 'assessment' ? data_kinds.detect { |k| k.key == key.to_s } : nil)
    def of(scope) = all.values.select { |k| k.scope == scope.to_s } + (scope.to_s == 'assessment' ? data_kinds : [])

    # Every kind, registered and data (the kinds' API)
    def listed = all.values + data_kinds

    def data_kinds
      defined?(AssessmentKinds) ? AssessmentKinds.all.reject { |k| all.key?("assessment:#{k.key}") } : []
    end

    # A name in the reader's language from names per language: the reader's, the installation's, else the first
    def name_in(names, lang = nil)
      h = names.is_a?(Hash) ? names : {}
      [lang, ::I18n.locale, (::Setting.default_language rescue nil)].compact.map(&:to_s).each { |l| return h[l].to_s if h[l].present? }
      h.values.map(&:to_s).detect(&:present?).to_s
    end
    def label(scope, key) = find(scope, key)&.label || key.to_s

    # The detail fields an event kind declared as holding people (register_event person_fields:); empty for a kind
    # that declared none or is not registered
    def person_fields(kind) = find(:event, kind)&.person_fields || []
    def person_field?(kind, field) = person_fields(kind).include?(field.to_s)

    # The detail fields an event kind declared as belonging to its target (register_event private_fields:)
    def private_fields(kind) = find(:event, kind)&.private_fields || []

    # The kinds offered in the writing box only when the function records.more_note_kinds is on; kommentar and skäl
    # always. Notes of every kind are shown and the API takes them.
    MORE_NOTE_KINDS = %w[occasion dispute question answer].freeze

    def offered_note?(key)
      return true unless MORE_NOTE_KINDS.include?(key.to_s)

      Features.on?('records.more_note_kinds')
    end

    def register_defaults
      %w[comment reason occasion dispute question answer].each { |k| register_note(k, plugin: :gk_records, label_key: "label_gk_records_note_#{k}") }
      # created, changed and voided are written by owner plugins with their own fields, so records declares none
      %w[created changed voided].each { |k| register_event(k, plugin: :gk_records, label_key: "label_gk_records_event_#{k}") }
      register_link('corrects', plugin: :gk_records, label_key: 'label_gk_records_link_corrects', acyclic: true,
                                reverse_label_key: 'label_gk_records_link_corrected_by')
      # The link made by hand is a kind of its own: symmetric, says no dependency, and needs a short reason
      register_link('manual', plugin: :gk_records, label_key: 'label_gk_records_link_manual', symmetric: true, manual: true)
      # Generic for any thing; made by the owner plugin's own buttons (people's Slå ihop and Det är olika personer),
      # never by hand on the links page. same_as goes from the one merged to the one that stays and is acyclic (a chain
      # ends at the one that stays); not_same has no direction.
      register_link('same_as', plugin: :gk_records, label_key: 'label_gk_records_link_same_as', acyclic: true,
                               reverse_label_key: 'label_gk_records_link_same_as_reverse')
      register_link('not_same', plugin: :gk_records, label_key: 'label_gk_records_link_not_same', symmetric: true)
      # A thing's verification status changed (GkRecords::Verification), on any target
      register_event(Verification::EVENT, plugin: :gk_records, label_key: 'label_gk_records_event_verification_changed')
      # The instance that owns a thing changed (GkRecords::Identity.change_owner!), on any target
      register_event(Identity::EVENT, plugin: :gk_records, label_key: 'label_gk_records_event_owner_changed')
    end
  end

  # Links seen from one thing (links_view): the other end of a link, and what the row on the thing says
  module Links
    module_function

    # [other key, other id, outgoing?]
    def other(link, key, id)
      if link.source_type == key.to_s && link.source_id == id.to_i
        [link.target_type, link.target_id, true]
      else
        [link.source_type, link.source_id, false]
      end
    end

    # The links in force on a thing: how many, how many per sort of thing at the other end, and those of a kind
    # its owner marked for attention
    def summary(key, id)
      links = ::GkRecordsLink.active.touching(key, id).order(:created_at, :id).to_a
      { total: links.size, by: links.group_by { |k| other(k, key, id).first }.transform_values(&:size),
        attention: links.select { |k| Kinds.find(:link, k.kind)&.attention } }
    end

    # The way from one thing to another along the links in force of one kind, source to target: the things passed,
    # the last one being the goal, or nil when there is no way. [key, id] pairs.
    def path(kind, from, to)
      seen = { from => nil }
      queue = [from]
      until queue.empty?
        at = queue.shift
        ::GkRecordsLink.active.where(kind: kind.to_s, source_type: at[0], source_id: at[1]).pluck(:target_type, :target_id).each do |nxt|
          nxt = [nxt[0].to_s, nxt[1].to_i]
          next if seen.key?(nxt)

          seen[nxt] = at
          if nxt == to
            out = [nxt]
            out.unshift(seen[out.first]) while seen[out.first]
            return out
          end
          queue << nxt
        end
      end
      nil
    end

    # A thing by its name for a message, or the text for a thing the reader may not see
    def ref_label(key, id)
      return "#{::I18n.t(:label_gk_records_note)} ##{id}" if key.to_s == 'gk_records_note'

      t = Targets.find(key)
      obj = t && t.model_class.find_by(id: id)
      return ::I18n.t(:text_gk_records_hidden_thing) unless obj && Targets.visible?(obj)

      obj.is_a?(::Issue) ? "##{obj.id}" : Targets.label(obj)
    end

    # The thing at one end, or nil when it is gone, not a registered target or not visible to the reader
    def thing(key, id, user = User.current)
      t = Targets.find(key)
      obj = t && t.model_class.find_by(id: id)
      obj && Targets.visible?(obj, user) ? obj : nil
    end

    # The state of the thing at the other end, { text:, closed: }: an issue's status and whether it is closed; nil for
    # the rest and for an issue the reader may not see (Issue#visible? asks with an OAuth token's scopes, the
    # Issue.visible list does not)
    def state(key, id, user = User.current)
      return nil unless key.to_s == 'issue'

      i = ::Issue.find_by(id: id)
      i&.visible?(user) ? { text: i.status.to_s, closed: i.closed? } : nil
    end

    # What a thing cites, the links in force from it of the kinds registered with citation:, oldest first (the
    # reader's view decides what of the other end is shown)
    def citations(obj)
      t = obj&.id && Targets.for_object(obj)
      kinds = Kinds.of(:link).select(&:citation).map(&:key)
      return [] unless t && kinds.any?

      ::GkRecordsLink.active.where(kind: kinds, source_type: t.key, source_id: obj.id).order(:created_at, :id).to_a
    end

    # Grouped by kind and direction: [[label, links], ...] in the order the kinds first appear
    def groups(links, key, id)
      links.group_by do |k|
        kind = Kinds.find(:link, k.kind)
        out = other(k, key, id).last
        both = kind.nil? || kind.symmetric
        [k.kind, both || out]
      end.map do |(kind_key, out), rows|
        kind = Kinds.find(:link, kind_key)
        label = kind ? kind.label : kind_key
        label = kind.reverse_label || ::I18n.t(:text_gk_records_dir_in, kind: label) if kind && !out
        [label, rows]
      end
    end
  end

  # Assessments: an occasion when someone valued a thing, kept whole. Owner plugins make them here, never records
  # itself: the kind is theirs (registered with Kinds.register_assessment), and so is what belongs to it. values:
  # [{ key:, label:, value: }] in the order to show. source says where it came from (a rule, a plugin's own
  # object); a new assessment from the same source on the same thing supersedes the one before it.
  # A value that is a person is a reference (GkRecords::Ref.person), never the name; a Principal becomes one.
  module Assessments
    module_function

    def record(target, kind, values:, outcome: nil, title: nil, title_translations: nil, basis: nil, user: User.current, origin: 'human', source: nil, at: Time.current)
      t = Targets.for_object(target)
      raise ArgumentError, "#{target.class.name} is not a registered records target" unless t
      raise ArgumentError, "assessment kind #{kind} is not registered" unless Kinds.find(:assessment, kind)

      before = ::GkRecordsAssessment.for_target(t.key, target.id).where(kind: kind.to_s, origin_source_id: source).order(:assessed_at, :id).last
      ::GkRecordsAssessment.create!(target_type: t.key, target_id: target.id, kind: kind.to_s, title: title,
                                 title_translations: title_translations.present? ? title_translations.to_h.transform_keys(&:to_s).to_json : nil, outcome: outcome.to_s.presence,
                                 data: Ref.normalize(Array(values).map { |v| v.to_h.transform_keys(&:to_s).slice('key', 'label', 'value') }).to_json,
                                 basis: basis, user_id: user&.id, assessed_at: at, supersedes_id: before&.id, origin: origin,
                                 origin_source_id: source)
    end

    # What the row on the thing says: how many, and the latest one
    def summary(key, id)
      scope = ::GkRecordsAssessment.for_target(key, id)
      { total: scope.count, latest: scope.newest_first.first }
    end
  end

  # Owner plugins write their events here, never records itself (P1: events are never changed or thinned)
  module Events
    module_function

    # Listeners on new events (triggers), keyed so a reloaded plugin replaces its own; called after commit
    def subscribers = (@subscribers ||= {})
    def subscribe(key, &block) = (subscribers[key.to_s] = block)

    def notify(event)
      subscribers.each do |key, block|
        block.call(event)
      rescue StandardError => e
        Rails.logger.warn("[gk_records] subscriber #{key} failed on event #{event.id}: #{e.class} #{e.message}")
      end
    end

    # details: { field => value or [before, after] }. A person is a reference (GkRecords::Ref.person, .people,
    # .change, or Ref.thing for a kind another plugin registered), never a name in plain text; a Principal object
    # in the details becomes a reference here. The fields that hold people are declared on the kind (person_fields).
    # reason_key is the place the reason was asked for.
    # A reason the system gives is a system text, reason_text_key: and reason_text_values: (SystemText; the name
    # reason_key was taken): the reason is then the text in the instance's language as the fallback, and the reason
    # note (or, on an issue, the event) keeps the key and values, so it is shown in the reader's language as it stood.
    # A reason given inside SystemText.as_reason that is exactly its text is taken the same way.
    def write(target, kind, details: {}, reason: nil, user: User.current, acting_user: nil, origin: 'human', project: nil, reason_key: nil,
              reason_text_key: nil, reason_text_values: nil)
      t = Targets.for_object(target)
      raise ArgumentError, "#{target.class.name} is not a registered records target" unless t
      raise ArgumentError, "event kind #{kind} is not registered" unless Kinds.find(:event, kind)

      keyed = nil
      if reason_text_key.present?
        reason, keyed = SystemText.attributes(reason_text_key, reason_text_values)
      elsif (claimed = SystemText.claim(reason))
        keyed = { text_key: claimed[0].to_s.first(200), text_values: claimed[1].to_json }
      end
      details = Ref.normalize(details || {})
      reason_note = nil
      if reason.present?
        note = GkRecordsNote.new(target_type: t.key, target_id: target.id, kind: 'reason', body: reason.to_s,
                              user_id: user&.id, origin: origin)
        note.assign_attributes(keyed) if keyed && SystemText.columns?(GkRecordsNote)
        if note.valid?
          note.save!
          reason_note = note
        elsif note.errors.include?(:target_type)
          # A target whose notes are refused (an issue: its notes are its journal) keeps the reason in the event's
          # own details instead, under "reason"; GkRecordsEvent#details_reason reads it back
          details = (details || {}).merge('reason' => reason.to_s)
        else
          note.save! # any other fault is raised as before
        end
      end
      # The place the reason was asked for (Reasons.check in this request, or given), so it can be offered again; a
      # #123 in the reason becomes a link to the issue
      key = reason.present? ? (reason_key || Reasons::Current.key) : nil
      attrs = { target_type: t.key, target_id: target.id, kind: kind.to_s, details: details.to_json, user_id: user&.id,
                acting_user_id: acting_user&.id, reason_note_id: reason_note&.id, origin: origin, project_id: project&.id }
      attrs[:reason_key] = key if key && GkRecordsEvent.column_names.include?("reason_key")
      attrs.merge!(keyed) if keyed && reason.present? && SystemText.columns?(GkRecordsEvent)
      event = GkRecordsEvent.create!(attrs)
      Reasons.link_issues(event, t.key, target.id, reason, user) if reason.present?
      event
    end
  end
end
