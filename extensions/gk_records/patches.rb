# frozen_string_literal: true

module GkRecords
  # Core patches, all applied from here; the modules stay beside the code they serve and say there what they assume
  # of core:
  # * Verification (verification.rb): Issue#gk_records_verification (the column's value, included),
  #   IssueQuery#issues, available_columns and the filter (IssueQueryPatch), TrackersController#create and #update
  #   (the tracker's choice and its levels, checked before core saves and kept after), and QueriesHelper#column_value
  #   (ColumnPill): the column in the HTML list as the status's pill; CSV and PDF keep the word (core's csv_value),
  #   every other column stays core's.
  # * Settings are change managed (settings_history.rb): Setting after_save and SettingsController around edit and
  #   plugin (the reason), and around plugin the verification levels drawn on a plugin's settings page.
  # * IssuesHelper#issue_history_tabs (IssueLinks::HelperPatch, issue_links.rb): the tab Kopplingar in the issue's
  #   history row; core has no hook for it.
  # * GkRecordsHelper in ActionView::Base: every view class inherits from it, so gk_records_list and the light
  #   formatter answer in every view and owner plugins render the list without their own helper; every name in the
  #   module carries the gk_records_ prefix.
  # * The export log (export_log.rb): ApplicationController#process_action, #send_data, #send_file and
  #   #send_file_headers! (ExportLog::ControllerPatch). Records loads before revisions, so revisions' names for core's
  #   exports (its own prepend on send_data and send_file_headers!) run first and pass the file on, named, to this,
  #   which notes it, or wraps it in a zip, and then to core.
  # The row Verifieringsstatus in the history is no patch: it is registered in core_stuff's register journal_detail
  # (Verification::HistoryLine). The identity hook goes on every registered target's model (Identity.install), as
  # targets register.
  # Applied directly from init.rb, which Redmine runs inside to_prepare at start and again after every reload in
  # development mode; every prepend and include is guarded, so a reload never adds a module twice.
  #
  # Two layers (gate.rb). protect! is applied whatever the gate to GK GUI Stuff says: the patches that write traces,
  # the settings' history (Setting, SettingsController) and the export log (ApplicationController). Inside them, what
  # needs the interface asks the gate itself: the reason on a settings page is asked for only where its field can be
  # drawn (SettingsHistory.reason_drawn?), the verification levels of a settings page are handled only with the gate
  # open (gk_records_verification_levels), and a zip with a manifest is made only with the gate open
  # (ExportLog.manifest_wanted?). apply! is applied only with the gate open: the patches that draw or sort, the
  # Verification status (Issue, IssueQuery, TrackersController, QueriesHelper), the tab Kopplingar (IssuesHelper) and
  # GkRecordsHelper in ActionView::Base, so that a plugin that asks respond_to?(:gk_records_list) gets no while the
  # gate is closed. The two never patch the same class, so the order between them does not matter.
  module Patches
    module_function

    # Always: the traces
    def protect!
      ::Setting.prepend(SettingsHistory::SettingPatch) unless ::Setting < SettingsHistory::SettingPatch
      ::SettingsController.prepend(SettingsHistory::ControllerPatch) unless ::SettingsController < SettingsHistory::ControllerPatch
      ::ApplicationController.prepend(ExportLog::ControllerPatch) unless ::ApplicationController < ExportLog::ControllerPatch
    end

    # Only with GK GUI Stuff: what draws or sorts
    def apply!
      ::Issue.include(Verification::IssueValue) unless ::Issue < Verification::IssueValue
      ::IssueQuery.prepend(Verification::IssueQueryPatch) unless ::IssueQuery < Verification::IssueQueryPatch
      ::TrackersController.prepend(Verification::TrackersControllerPatch) unless ::TrackersController < Verification::TrackersControllerPatch
      ::QueriesHelper.prepend(Verification::ColumnPill) unless ::QueriesHelper < Verification::ColumnPill
      ::IssuesHelper.prepend(IssueLinks::HelperPatch) unless ::IssuesHelper < IssueLinks::HelperPatch
      ActionView::Base.include(::GkRecordsHelper) unless ActionView::Base.include?(::GkRecordsHelper)
    end
  end
end
