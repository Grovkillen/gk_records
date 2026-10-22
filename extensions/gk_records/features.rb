# frozen_string_literal: true

module GkRecords
  # Records' functions (the owner, human test records_1021: "måste man kunna aktivera händelser, inläsningar, skäl om man
  # vill använda sig av det", "vi måste låta de beroende pluginen själva aktivera funktioner som de behöver utan att man
  # ska behöva klicka sig emellan olika plugin-inställningssidor"; the choice "Dölja sidor och menyer"). A function is
  # on when the administrator turns it on in records' settings, when a plugin asked for it (request), or when a GK
  # plugin known to use it is installed. Off hides its pages, menu rows and tabs; nothing is deleted, events are always
  # written (retention and the history rely on them), and it all shows again when it is turned on.
  #   GkRecords::Features.request('links', by: :gk_mine)   # in a plugin's init, for a plugin records does not know
  #   GkRecords::Features.on?('events')
  # Verification status has no switch of its own: it is on when a tracker has it (Administration > Trackers) or a
  # plugin asked for it. Reasons keep their own page and modes (Administration > Skäl), off for a new installation.
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
      'gk_queries' => 'GK Queries', 'gk_recurring' => 'GK Recurring', 'gk_retention' => 'GK Retention', 'gk_revisions' => 'GK Revisions',
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

    def on?(key)
      k = key.to_s
      return Verification.tracker_ids.any? || requests[k].any? if k == 'verification'

      chosen?(k) || turned_on_by(k).any?
    end

    # The GK plugins that would use it but are not installed
    def missing_users(key) = Array(USERS[key.to_s]).reject { |p| installed?(p) }
  end
end
