# frozen_string_literal: true
# Revision: 0.00.000
# One shared layer of notes, events and links on everything that is not an issue: other plugins register their models as
# targets and their kinds, write events with GkRecords::Events.write, and render the list partial on their pages.
# Nothing is edited or deleted: a note is corrected by a new note (link "corrects") and voided with a reason.
# Notes are light Markdown only (5.6c): core's formatter, then everything above the level is stripped.
# Registry and hooks live in extensions/, models and views in app/.
# Depends on: gk_core_stuff required; optional gk_queries, gk_compat, gk_fields, gk_gui_stuff, gk_icons, gk_people,
# gk_revisions, gk_scenarios.

require_relative 'extensions/gk_records/registry'
require_relative 'extensions/gk_records/api_scope'
require_relative 'extensions/gk_records/features'
require_relative 'extensions/gk_records/system_text'
require_relative 'extensions/gk_records/identity'
require_relative 'extensions/gk_records/assessment_kinds'
require_relative 'extensions/gk_records/verification'
require_relative 'extensions/gk_records/reasons'
require_relative 'extensions/gk_records/visibility'
require_relative 'extensions/gk_records/settings_history'
require_relative 'extensions/gk_records/issue_links'
require_relative 'extensions/gk_records/readings'
require_relative 'extensions/gk_records/document_import'
require_relative 'extensions/gk_records/events_csv'
require_relative 'extensions/gk_records/registrations'
require_relative 'extensions/gk_records/export_log'
require_relative 'extensions/gk_records/patches'

Redmine::Plugin.register :gk_records do
  name        'GK Records'
  author      'Jimmy Westberg'
  description 'Records: one shared layer for notes, events and links on everything that is not an issue'
  version     '1.04.000'
  requires_redmine version_or_higher: '6.0.0'

  # mark_restricted_people is off for a new installation (a default only); the functions (GkRecords::Features), the
  # number on the tabs and the name of Verifieringsstatus per language are off or empty (human test records_1021); the
  # export log is on
  settings default: { 'note_max_length' => '4000', 'show_origin_badge' => '1', 'mark_restricted_people' => '0',
                    'verification_tracker_ids' => [], 'features' => {}, 'tab_counts' => '0', 'export_log' => '1' },
           partial: 'settings/gk_records_settings'

  # The project module Händelser (1.01.000): Se händelser per project, the project's tab and, under Administration,
  # the events of the projects where the reader has it. Administrators see everything, the events without a project
  # only they. A target's own events follow who may see the target, as before.
  project_module :gk_records_events do
    permission :gk_records_view_events, { gk_records_events: [:index] }, require: :loggedin, read: true
  end
  menu :project_menu, :gk_records_events, { controller: 'gk_records_events', action: 'index' },
       caption: :label_gk_records_events, param: :project_id, after: :activity,
       if: ->(_p) { GkRecords::Features.on?('events') }

  # The event log is a query (T-QUERY): with gk_queries it lists there, otherwise the plugin's own page; a function that
  # is off has no menu row (GkRecords::Features)
  menu :admin_menu, :gk_records_events,
       (defined?(GkQueries) ? { controller: 'gk_queries', action: 'show', list: 'records_events' } : { controller: 'gk_records_events', action: 'index' }),
       caption: :label_gk_records_events, icon: 'history', html: { class: 'icon' }, after: :gk_workflow_rules_rules,
       if: ->(_p) { GkRecords::Features.on?('events') }
  # Every reason field's mode, for the installation and per place
  menu :admin_menu, :gk_records_reasons, { controller: 'gk_records_reasons', action: 'index' },
       caption: :label_gk_records_reasons, icon: 'comment', html: { class: 'icon' }, after: :gk_records_events
  # Every import and sync run, beside Händelser
  menu :admin_menu, :gk_records_readings, { controller: 'gk_records_readings', action: 'index' },
       caption: :label_gk_records_readings, icon: 'import', html: { class: 'icon' }, after: :gk_records_events,
       if: ->(_p) { GkRecords::Features.on?('readings') }

  # OAuth scopes for the REST API (GkRecords::ApiScope); a role grants nothing with them. A token reads the kinds, the
  # readings list and the reasons only with the read scope and changes a reason mode only with the manage scope; the
  # last three stay for administrators.
  permission :gk_records_api_read, {}, require: :loggedin
  permission :gk_records_api_manage, {}, require: :loggedin

  # The export log: who may see the exports, downloads and prints in a project (the events ask it); outside the project
  # module
  permission :gk_records_view_exports, {}, require: :member
end

# The plugin's own kinds (other plugins add theirs the same way); registered again after a reload
GkRecords::Kinds.register_defaults
# Settings are change managed (settings_history): the target, the kind and the two core patches
GkRecords::SettingsHistory.register!
# The reasons' modes: the target, the kinds and records' own places; other plugins declare theirs
GkRecords::Reasons.register_records!
# The functions' register: the target and the kind of a switch, and records' own declared function (the note kinds
# beyond kommentar and skäl, off for a new installation); other plugins declare theirs
GkRecords::Features.register_records!
# A reading is a target, so events can be written on it
GkRecords::Readings.register_target!
# The issue is records' own target (before, workflow_rules registered it)
GkRecords::IssueLinks.register_target!
# An assessment is a target, so it can carry a verification status and its events
GkRecords::Verification.register_assessment_target!
# Core's document is a target (Läs in dokument points its fields to the reading and links it)
GkRecords::DocumentImport.register_target!
# Core patches (extensions/gk_records/patches.rb): the column and the filter Verifieringsstatus in the issue list, the
# settings' history, the tab Kopplingar in the issue's history row and gk_records_list and the light formatter in
# every view (so owner plugins render the list without their own helper); applied here and again on every reload
GkRecords::Patches.apply!
GkRecords::Verification.register_hooks!
Redmine::Hook.add_listener(GkRecords::SettingsHooks) unless Redmine::Hook.listeners.any?(GkRecords::SettingsHooks)
Redmine::Hook.add_listener(GkRecords::IssueHooks) unless Redmine::Hook.listeners.any?(GkRecords::IssueHooks)
Redmine::Hook.add_listener(GkRecords::ReasonHooks) unless Redmine::Hook.listeners.any?(GkRecords::ReasonHooks)
# The origin line on a document's page and Läs in dokument on the Dokument tab
Redmine::Hook.add_listener(GkRecords::DocumentImportHooks) unless Redmine::Hook.listeners.any?(GkRecords::DocumentImportHooks)
# Plugins that load before records (alphabetical: people, queries) register their targets and kinds here
Redmine::Plugin.all.each do |pl|
  mod = pl.id.to_s.camelize.safe_constantize
  mod.register_records! if mod.respond_to?(:register_records!)
end
# The export log's kinds, and the project and the wiki page as targets where no plugin before registered them
GkRecords::ExportLog.register!
Redmine::Hook.add_listener(GkRecords::ExportLogHooks) unless Redmine::Hook.listeners.any?(GkRecords::ExportLogHooks)
# The identity hook on every target known so far; after a code reload the models are new classes, and targets registered
# once (after initialize) get the hook again here. Targets registered later install it themselves.
GkRecords::Identity.install_all!
# The row Verifieringsstatus in the issue's history, in core_stuff's register (core_stuff loads before records)
Rails.configuration.after_initialize { GkRecords::Verification::HistoryLine.register! }

# The event log as a registered query when gk_queries is there (it loads first, alphabetically)
if defined?(GkQueries)
  # the CSV is records' own (1.01.000), the same as from the page; csv: is read by gk_queries that has it
  csv_opt = GkQueries::Entry.members.include?(:csv) ? { csv: ->(rows, _query) { GkRecords::EventsCsv.generate(rows) } } : {}
  GkQueries::Registry.register('records_events', klass: 'GkRecordsEventQuery', plugin: :gk_records, label: :label_gk_records_events,
                                                  visible: ->(user) { user.admin? }, **csv_opt)
end
Rails.configuration.after_initialize do
  # The reasons' modes and the function switches name the administrator who set them
  ::GkPeople::Processing.declare(:gk_records_reason_modes, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
  ::GkPeople::Processing.declare(:gk_records_features, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
  # The readings name who ran them, and their fields point at registered persons
  if defined?(::GkPeople::Processing)
    %i[gk_records_readings gk_records_field_origins gk_records_verifications].each { |t| ::GkPeople::Processing.declare(t, category: 'records', plugin: :gk_records) }
  end
  # The document list's template is named by revisions' one rule (revisions loads after records)
  GkRecords::DocumentImport.declare_names!
  # and so is the event log's CSV
  GkRecords::EventsCsv.declare_names!
  # The identities point at things, people among them (a user, a register person)
  if defined?(::GkPeople::Processing)
    ::GkPeople::Processing.declare(:gk_records_identities, category: 'records', plugin: :gk_records)
    if ::GkPeople::Processing.respond_to?(:declare_ref)
      ::GkPeople::Processing.declare_ref(:gk_records_identities, type_column: :target_type, type_value: 'user', id_column: :target_id, kind: :user)
      ::GkPeople::Processing.declare_ref(:gk_records_identities, type_column: :target_type, type_value: 'person', id_column: :target_id, kind: :person)
    end
  end
  # Every plugin has registered its targets: the hooks, the origin filled in when the instance has an id, and the things
  # without an identity get one (batched, idempotent; not under rake)
  GkRecords::Identity.boot!
  # The text revisions name no one, but are records' table like the others; the keys in use brought up to date
  ::GkPeople::Processing.declare(:gk_records_text_revisions, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
  GkRecords::SystemText.boot!
end

# The data assessment kinds' names in other languages under fields' Översättningar (records keeps them in its settings)
require_relative 'extensions/gk_records/kind_texts'
Rails.configuration.after_initialize { GkRecords::KindTexts.register! }
