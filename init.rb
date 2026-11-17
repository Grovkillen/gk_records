# frozen_string_literal: true
# Revision: 0.00.001
# One shared layer of notes, events and links on everything that is not an issue: other plugins register their models as
# targets and their kinds, write events with GkRecords::Events.write, and render the list partial on their pages.
# Nothing is edited or deleted: a note is corrected by a new note (link "corrects") and voided with a reason.
# Notes are light Markdown only: core's formatter, then everything above the level is stripped.
# Registry and hooks live in extensions/, models and views in app/.
# Depends on: gk_core_stuff and gk_gui_stuff (>= 1.05.000) required; optional gk_queries, gk_compat, gk_fields, gk_icons,
# gk_people, gk_revisions, gk_scenarios. Without gk_gui_stuff (missing, too old or not active: GkRecords.gui?, gate.rb)
# the pages, the menus, what records draws on other pages and the API are closed, and the settings page says so. The
# registers still answer, events, notes, assessments and links are still written, and the project module and the
# permissions are still registered. The migrations run all the same.

require_relative 'extensions/gk_records/gate'
require_relative 'extensions/gk_records/registry'
require_relative 'extensions/gk_records/api_scope'
require_relative 'extensions/gk_records/footprint' # what a setting or a function changes on the pages, as data
require_relative 'extensions/gk_records/features'
require_relative 'extensions/gk_records/appearance_settings'
require_relative 'extensions/gk_records/appearance_kinds'
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
require_relative 'extensions/gk_records/event_search'
require_relative 'extensions/gk_records/registrations'
require_relative 'extensions/gk_records/export_log'
require_relative 'extensions/gk_records/patches'
# The data assessment kinds' and the verification places' words under fields' Översättningar
require_relative 'extensions/gk_records/kind_texts'
require_relative 'extensions/gk_records/verification_texts'

Redmine::Plugin.register :gk_records do
  name        'GK Records'
  author      'Jimmy Westberg'
  description 'Records: one shared layer for notes, events and links on everything that is not an issue'
  version     '1.06.000'
  requires_redmine version_or_higher: '6.0.0'

  # mark_restricted_people is off for a new installation (a default only); the functions (GkRecords::Features), the
  # number on the tabs and the name of Verifieringsstatus per language are off or empty (human test records_1021); the
  # export log is on
  settings default: { 'note_max_length' => '4000', 'show_origin_badge' => '1', 'mark_restricted_people' => '0',
                    'verification_tracker_ids' => [], 'verification_places' => {}, 'features' => {}, 'tab_counts' => '0', 'export_log' => '1' },
           partial: 'settings/gk_records_settings'

  # The project module Händelser (1.01.000): Se händelser per project, the project's tab and, under Administration,
  # the events of the projects where the reader has it. Administrators see everything, the events without a project
  # only they. A target's own events follow who may see the target, as before. The module and records' permissions
  # are registered whatever the gate to GK GUI Stuff says (gate.rb): a role or a project saved while they were away
  # would lose them. With the gate closed they open nothing (the controllers answer 404, the menu rows are gone).
  project_module :gk_records_events do
    permission :gk_records_view_events, { gk_records_events: [:index] }, require: :loggedin, read: true
  end
  menu :project_menu, :gk_records_events, { controller: 'gk_records_events', action: 'index' },
       caption: :label_gk_records_events, param: :project_id, after: :activity,
       if: ->(_p) { GkRecords.gui? && GkRecords::Features.on?('events') }

  # The event log is a query (T-QUERY): with gk_queries it lists there, otherwise the plugin's own page; a function that
  # is off has no menu row (GkRecords::Features)
  menu :admin_menu, :gk_records_events,
       (defined?(GkQueries) ? { controller: 'gk_queries', action: 'show', list: 'records_events' } : { controller: 'gk_records_events', action: 'index' }),
       caption: :label_gk_records_events, icon: 'history', html: { class: 'icon' }, after: :gk_workflow_rules_rules,
       if: ->(_p) { GkRecords.gui? && GkRecords::Features.on?('events') }
  # Every reason field's mode, for the installation and per place
  menu :admin_menu, :gk_records_reasons, { controller: 'gk_records_reasons', action: 'index' },
       caption: :label_gk_records_reasons, icon: 'comment', html: { class: 'icon' }, after: :gk_records_events,
       if: ->(_p) { GkRecords.gui? }
  # Every import and sync run, beside Händelser
  menu :admin_menu, :gk_records_readings, { controller: 'gk_records_readings', action: 'index' },
       caption: :label_gk_records_readings, icon: 'import', html: { class: 'icon' }, after: :gk_records_events,
       if: ->(_p) { GkRecords.gui? && GkRecords::Features.on?('readings') }

  # OAuth scopes for the REST API (GkRecords::ApiScope); a role grants nothing with them. A token reads the kinds, the
  # readings list and the reasons only with the read scope and changes a reason mode only with the manage scope; the
  # last three stay for administrators.
  # The export log: who may see the exports, downloads and prints in a project (the events ask it); outside the project
  # module. Registered whatever the gate says, like the module above.
  permission :gk_records_api_read, {}, require: :loggedin
  permission :gk_records_api_manage, {}, require: :loggedin
  permission :gk_records_view_exports, {}, require: :member
end

# Everything below is records at work, in two layers (gate.rb). What writes traces is registered and patched whatever
# the gate to GK GUI Stuff says: the targets and the kinds, the functions' register, the identities, the settings'
# history, the export log and the print script. What a person works with is registered only with the gate open (the
# lines with "if gui"): the reason places, the appearance settings, the verification places, the patches that draw,
# the view listeners and what records registers in other plugins. The lines stand in one order for both, so that the
# order with the gate open is the same as before. gate.rb is required above and GK GUI Stuff loads before records, so
# the gate answers here.
gui = GkRecords.gui?

# "med manifest" as a row under Appearance, off from the start
GkRecords::ExportLog.register_manifest_row! if gui
# The plugin's own kinds (other plugins add theirs the same way); registered again after a reload
GkRecords::Kinds.register_defaults
# Settings are change managed (settings_history): the target and the kind (the two core patches: Patches.protect!)
GkRecords::SettingsHistory.register!
# The link kind of a #123 in a reason: always, so the links are made whenever an event with a reason is written
GkRecords::Reasons.register_link!
# The reasons' modes: the target and the kind of a changed mode, always, so a mode changed while the gate is closed
# leaves its event
GkRecords::Reasons.register_target!
# and records' own places; other plugins declare theirs
GkRecords::Reasons.register_records! if gui
# The functions' register: the target and the kind of a switch, and records' own declared function (the note kinds
# beyond kommentar and skäl, off for a new installation); other plugins declare theirs
GkRecords::Features.register_records!
# The register of appearance settings: the target and the kinds of an administrator's change and of a person's own
# choice, always, so a change made while the gate is closed leaves its event; other plugins declare their settings,
# which stay behind the gate
GkRecords::AppearanceSettings.register_records!
# A reading is a target, so events can be written on it
GkRecords::Readings.register_target!
# The issue is records' own target (before, workflow_rules registered it); every issue event stands on it
GkRecords::IssueLinks.register_target!
# An assessment is a target, so it can carry a verification status and its events
GkRecords::Verification.register_assessment_target!
# Records' own verification places: the issue default (each tracker falls back to it) and the assessments
GkRecords::Verification.register_places! if gui
# Core's document is a target (Läs in dokument points its fields to the reading and links it)
GkRecords::DocumentImport.register_target!
# Core patches (extensions/gk_records/patches.rb), applied here and again on every reload. Always: the settings'
# history and the export log. Only with GK GUI Stuff: the column and the filter Verifieringsstatus in the issue list,
# the tab Kopplingar in the issue's history row and gk_records_list and the light formatter in every view (so owner
# plugins render the list without their own helper).
GkRecords::Patches.protect!
if gui
  GkRecords::Patches.apply!
  GkRecords::Verification.register_hooks!
  Redmine::Hook.add_listener(GkRecords::SettingsHooks) unless Redmine::Hook.listeners.any?(GkRecords::SettingsHooks)
  Redmine::Hook.add_listener(GkRecords::IssueHooks) unless Redmine::Hook.listeners.any?(GkRecords::IssueHooks)
  Redmine::Hook.add_listener(GkRecords::ReasonHooks) unless Redmine::Hook.listeners.any?(GkRecords::ReasonHooks)
  # The origin line on a document's page and Läs in dokument on the Dokument tab
  Redmine::Hook.add_listener(GkRecords::DocumentImportHooks) unless Redmine::Hook.listeners.any?(GkRecords::DocumentImportHooks)
end
# Plugins that load before records (alphabetical) and have register_records! register their targets and kinds here,
# whatever the gate says: without it they would write no events while the gate is closed. With the gate closed they
# are called in a state they were never called in before, so one that fails then is logged and passed over: it must
# not take the export log, the print script and the identities below with it. With the gate open a fault is raised
# as before.
Redmine::Plugin.all.each do |pl|
  mod = pl.id.to_s.camelize.safe_constantize
  begin
    mod.register_records! if mod.respond_to?(:register_records!)
  rescue StandardError => e
    raise if gui

    Rails.logger.warn("[gk_records] register_records! of #{pl.id} failed while the gate is closed: #{e.class} #{e.message}")
  end
end
# The export log's kinds, and the project and the wiki page as targets where no plugin before registered them
GkRecords::ExportLog.register!
# The print script on every page is trace and has no gate; its choice "med manifest" asks the gate itself
Redmine::Hook.add_listener(GkRecords::ExportLogHooks) unless Redmine::Hook.listeners.any?(GkRecords::ExportLogHooks)
# The identity hook on every target known so far; after a code reload the models are new classes, and targets registered
# once (after initialize) get the hook again here. Targets registered later install it themselves.
GkRecords::Identity.install_all!
# The row Verifieringsstatus in the issue's history, in core_stuff's register (core_stuff loads before records)
Rails.configuration.after_initialize { GkRecords::Verification::HistoryLine.register! } if gui

# The event log as a registered query when gk_queries is there (it loads first, alphabetically)
if gui && defined?(GkQueries)
  # the CSV is records' own (1.01.000), the same as from the page; csv: is read by gk_queries that has it
  csv_opt = GkQueries::Entry.members.include?(:csv) ? { csv: ->(rows, _query) { GkRecords::EventsCsv.generate(rows) } } : {}
  GkQueries::Registry.register('records_events', klass: 'GkRecordsEventQuery', plugin: :gk_records, label: :label_gk_records_events,
                                                  visible: ->(user) { user.admin? }, **csv_opt)
end
Rails.configuration.after_initialize do
  if gui
    # The reasons' modes and the function switches name the administrator who set them
    ::GkPeople::Processing.declare(:gk_records_reason_modes, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
    ::GkPeople::Processing.declare(:gk_records_features, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
    # and so do the appearance settings, whose person rows are a person's own choices
    ::GkPeople::Processing.declare(:gk_records_appearance_settings, category: 'records', plugin: :gk_records) if defined?(::GkPeople::Processing)
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
  end
  # Every plugin has registered its targets: the hooks, the origin filled in when the instance has an id, and the things
  # without an identity get one (batched, idempotent; not under rake). Always: the identity is a mark written when a
  # thing is made, so nothing has to be mended afterwards.
  GkRecords::Identity.boot!
  # The text revisions name no one, but are records' table like the others
  ::GkPeople::Processing.declare(:gk_records_text_revisions, category: 'records', plugin: :gk_records) if gui && defined?(::GkPeople::Processing)
  # The keys in use brought up to date. Always: a reason the system gives is written with its key in Events.write.
  GkRecords::SystemText.boot!
end

if gui
  # The data assessment kinds' names in other languages under fields' Översättningar (records keeps them in its settings)
  Rails.configuration.after_initialize { GkRecords::KindTexts.register! }
  # The words and the row's name of every verification place under fields' Översättningar (records keeps them in its settings)
  Rails.configuration.after_initialize { GkRecords::VerificationTexts.register! if defined?(::GkFields::Translations) }
end
