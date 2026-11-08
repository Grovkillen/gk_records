# frozen_string_literal: true

module GkRecords
  # Records' functions. A function is
  # on when the administrator turns it on in records' settings, when a plugin asked for it (request), or when a GK
  # plugin known to use it is installed. Off hides its pages, menu rows and tabs; nothing is deleted, events are always
  # written (retention and the history rely on them), and it all shows again when it is turned on.
  #   GkRecords::Features.request('links', by: :gk_mine)   # in a plugin's init, for a plugin records does not know
  #   GkRecords::Features.on?('events')
  # Verification status has no switch of its own: it is on when a tracker has it (Administration > Trackers) or a
  # plugin asked for it. Reasons keep their own page and modes (Administration > Skäl), off for a new installation.
  # The shared register of the GK plugins' functions is here too. Every plugin declares the functions it can hide, with
  # a name and a short explanation, and asks before it draws a menu row, a tab, a section, a button or a column:
  #   GkRecords::Features.register('tags.marks', plugin: :gk_tags, label: :label_gk_feature_tags_marks,
  #                                help: :text_gk_feature_tags_marks)
  #   GkRecords::Features.on?('tags.marks')
  # A declared function is off until the administrator switches it on (Administration > Funktioner, gui_stuff's page
  # reads this register), unless its registration says default: true;
  # a key nobody declared is off. The default stands in the registration and in the plugin's
  # registrations.yml, and the first switch away from it is an event like any other. A function that is off draws
  # nothing; its data stays. Every switch is an event on the function, with the reason. A plugin without records has
  # every function off.
  module Features
    ALL = %w[links assessments events readings verification].freeze
    SWITCHED = %w[links assessments events readings].freeze
    # The GK plugins that use each function (what their code calls in records), so that the settings say who would
    # use it when none of them is installed
    USERS = {
      'links' => %w[gk_people gk_project_types gk_recurring gk_tags],
      'assessments' => %w[gk_workflow_rules],
      'events' => %w[gk_access gk_budget gk_checklists gk_fields gk_gis gk_graphic_profiles gk_gui_stuff gk_icons gk_people
                     gk_project_types gk_publishing gk_queries gk_retention gk_revisions gk_signoff gk_tags gk_templates
                     gk_triggers gk_workflow_rules],
      'readings' => %w[gk_gis gk_people gk_project_types],
      'verification' => %w[gk_signoff gk_project_types]
    }.freeze
    # A plugin's name when it is not installed (what its init.rb calls it)
    NAMES = {
      'gk_access' => 'GK Access', 'gk_budget' => 'GK Budget', 'gk_checklists' => 'GK Checklists', 'gk_fields' => 'GK Fields',
      'gk_gis' => 'GK GIS', 'gk_graphic_profiles' => 'GK Graphic Profiles', 'gk_gui_stuff' => 'GK GUI Stuff', 'gk_icons' => 'GK Icons',
      'gk_people' => 'GK People', 'gk_project_types' => 'GK Project Types', 'gk_publishing' => 'GK Publishing',
      'gk_queries' => 'GK Queries', 'gk_readup' => 'GK Readup', 'gk_recurring' => 'GK Recurring', 'gk_retention' => 'GK Retention', 'gk_revisions' => 'GK Revisions',
      'gk_signoff' => 'GK Signoff', 'gk_tags' => 'GK Tags', 'gk_templates' => 'GK Templates', 'gk_triggers' => 'GK Triggers',
      'gk_workflow_rules' => 'GK Workflow Rules'
    }.freeze

    module_function

    def requests = (@requests ||= Hash.new { |h, k| h[k] = [] })

    # A plugin asks for a function when it starts; registered again after a reload
    def request(key, by:)
      k = key.to_s
      raise ArgumentError, "records has no function #{k}" unless ALL.include?(k)

      requests[k] |= [by.to_s]
    end

    def installed?(plugin) = Redmine::Plugin.registered_plugins.key?(plugin.to_sym)
    def name_of(plugin) = Redmine::Plugin.registered_plugins[plugin.to_sym]&.name || NAMES[plugin.to_s] || plugin.to_s

    # Who turns it on: the plugins that asked for it, then the installed plugins known to use it
    def turned_on_by(key)
      k = key.to_s
      (requests[k] + Array(USERS[k]).select { |p| installed?(p) }).uniq
    end

    def chosen?(key)
      s = ::Setting.plugin_gk_records
      v = s.is_a?(Hash) && s['features'].is_a?(Hash) ? s['features'][key.to_s] : nil
      v.to_s == '1'
    rescue StandardError
      false
    end

    # Records' own functions as above; any other key is a declared function, on only when switched on
    def on?(key)
      k = key.to_s
      return Verification.tracker_ids.any? || requests[k].any? if k == 'verification'
      return switched_on?(k) unless ALL.include?(k)

      chosen?(k) || turned_on_by(k).any?
    end

    def off?(key) = !on?(key)

    # The GK plugins that would use it but are not installed
    def missing_users(key) = Array(USERS[key.to_s]).reject { |p| installed?(p) }

    # A declared function of another plugin (register)
    # related: functions shown as "Goes with"; requires: functions that must be on with it (the page asks); footprint and
    # applies: what it adds to or removes from the pages and how (footprint.rb)
    Declared = Struct.new(:key, :plugin, :label_key, :help_key, :admin_only, :default, :related, :requires, :footprint, :applies,
                          keyword_init: true) do
      def label = ::I18n.t(label_key, default: key)
      def help = help_key ? ::I18n.t(help_key, default: '') : ''
      def plugin_name = Redmine::Plugin.registered_plugins[plugin.to_sym]&.name || plugin.to_s
    end

    # The target and the event kind of a switch
    TARGET = 'feature'
    KIND = 'feature_switched'
    TTL = 30 # seconds before another process's switch is seen

    def declared = (@declared ||= {})

    # Registered again after a reload; default: true is on until the administrator switches it off. footprint: what
    # the function puts on the pages (adds:, removes:, anchors:, elements:, pages:) and applies: how (footprint.rb); a
    # new function with a visible effect declares them, and an anchor that breaks footprint.rb's rules is left out and
    # logged.
    def register(key, plugin:, label: nil, help: nil, admin_only: false, default: false, related: [], requires: [],
                 footprint: nil, applies: nil)
      k = key.to_s
      raise ArgumentError, "records: #{k} is one of records' own functions" if ALL.include?(k)
      raise ArgumentError, "records: #{k} is an appearance setting" if defined?(AppearanceSettings) && AppearanceSettings.find(k)

      fp = Footprint.normalize(footprint, k)
      how = Footprint.applies(applies, k)
      declared[k] = Declared.new(key: k, plugin: plugin.to_s, label_key: label || :"label_gk_feature_#{k.tr('.', '_')}",
                                 help_key: help, admin_only: admin_only ? true : false, default: default ? true : false,
                                 related: Array(related).map(&:to_s), requires: Array(requires).map(&:to_s),
                                 footprint: stable_footprint(k, fp), applies: how)
    end

    # The footprint with only the anchors that keep to the rules; the others are logged
    def stable_footprint(key, footprint)
      bad = Footprint.problems(footprint)
      bad.each { |a, why| Rails.logger.warn("[gk_records] #{key}: anchor #{a} left out of the footprint (#{why})") } if bad.any? && defined?(Rails.logger) && Rails.logger
      bad.any? ? Footprint.stable(footprint) : footprint
    end

    def find(key) = declared[key.to_s]

    # What a declared function affects (Påverkar), nil when nothing is described
    def footprint(key) = find(key)&.footprint

    # Whether the function says what it affects: a footprint, or applies none
    def described?(key)
      f = find(key)
      f ? Footprint.described?(f.footprint) || f.applies == ['none'] : false
    end

    def switched_on?(key)
      f = find(key)
      return false unless f

      stored.key?(f.key) ? stored[f.key] == true : f.default
    end

    # The memory is shared by the threads of the process. Inside a transaction the table answers and the memory is left
    # alone: another thread's read cannot stand in for what this one has written, and what may be rolled back stays here.
    def stored
      return read_stored if ::GkRecordsFeature.connection.open_transactions.positive?

      if @stored.nil? || @loaded_at.nil? || Time.current - @loaded_at > TTL
        @stored = read_stored
        @loaded_at = Time.current
      end
      @stored
    rescue StandardError
      {}
    end

    def read_stored = ::GkRecordsFeature.table_exists? ? ::GkRecordsFeature.pluck(:key, :enabled).to_h : {}

    def forget! = (@stored = nil)

    # The administrator's switch, with the reason and the place it was asked for; an event on the function
    def set!(key, enabled, reason: nil, user: User.current, reason_key: nil)
      f = find(key) or raise ArgumentError, "gk_records: no declared function #{key}"
      forget! # decide from the table, not from memory
      before = switched_on?(f.key)
      row = ::GkRecordsFeature.find_or_initialize_by(key: f.key)
      row.enabled = enabled ? true : false
      row.updated_by_id = user&.logged? ? user.id : nil
      row.save!
      forget!
      record(row, before, row.enabled, reason, reason_key) if before != row.enabled
      row
    end

    # Several switches with one reason, in one transaction: an unknown key refuses them all. Returns the keys that changed.
    def set_many!(changes, reason: nil, user: User.current, reason_key: nil)
      changed = []
      ::GkRecordsFeature.transaction do
        changes.each do |k, v|
          f = find(k) or raise ArgumentError, "gk_records: no declared function #{k}"
          before = switched_on?(f.key)
          set!(f.key, v, reason: reason, user: user, reason_key: reason_key)
          changed << f.key if before != (v ? true : false)
        end
      end
      forget! # a read by another thread before the commit is not kept
      changed
    end

    # The newest switch of each function: { key => { event:, user:, at:, reason:, enabled: } }; one query for the rows and
    # one for the events, never one per function
    def last_changes(keys = nil)
      return {} unless defined?(::GkRecordsEvent) && ::GkRecordsFeature.table_exists?

      scope = keys ? ::GkRecordsFeature.where(key: Array(keys).map(&:to_s)) : ::GkRecordsFeature.all
      ids = scope.pluck(:id, :key).to_h
      return {} if ids.empty?

      newest = ::GkRecordsEvent.where(target_type: TARGET, kind: KIND, target_id: ids.keys).group(:target_id).select('MAX(id)')
      ::GkRecordsEvent.where(id: newest).includes(:user, :reason_note).each_with_object({}) do |e, h|
        h[ids[e.target_id]] = { event: e, user: e.user, at: e.created_at, reason: e.reason_text.to_s.squish,
                                enabled: Array(e.details_hash['enabled']).last }
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_records] functions' last changes not read: #{e.message}")
      {}
    end

    def by_plugin = declared.values.group_by(&:plugin).sort_by { |p, _| Redmine::Plugin.registered_plugins[p.to_sym]&.name.to_s }

    def record(row, before, after, reason, reason_key = nil)
      return unless Targets.find(TARGET) && Kinds.find(:event, KIND)

      Events.write(row, KIND, details: { 'feature' => row.key, 'enabled' => [before, after] }, reason: reason.presence,
                              user: User.current.logged? ? User.current : nil, reason_key: reason_key)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] function switch not recorded for #{row.key}: #{e.message}")
    end

    # The page that switches them is gui_stuff's; without it the function's events have no page to lead to
    def register_records!
      Targets.register(TARGET, model: 'GkRecordsFeature',
                               visible: ->(_f, user) { user.admin? }, editable: ->(_f, user) { user.admin? },
                               label: ->(f) { "#{::I18n.t(:label_gk_records_features)}: #{f.name}" },
                               url: ->(_f) { defined?(::GkGuiStuff) ? Rails.application.routes.url_helpers.gk_gui_stuff_features_path : nil })
      Kinds.register_event(KIND, plugin: :gk_records, label_key: 'label_gk_records_event_feature_switched', target: TARGET)
      register('records.more_note_kinds', plugin: :gk_records, label: :label_gk_feature_records_more_note_kinds,
                                          help: :text_gk_feature_records_more_note_kinds)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] function register not ready: #{e.message}")
    end
  end
end
