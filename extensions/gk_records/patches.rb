# frozen_string_literal: true

module GkRecords
  # Core patches, all applied from here; the modules stay beside the code they serve and say there what they assume
  # of core:
  # * Verification (verification.rb): Issue#gk_records_verification (the column's value, included),
  #   IssueQuery#issues, available_columns and the filter (IssueQueryPatch), TrackersController#create and #update
  #   (the tracker's choice kept).
  # * Settings are change managed (settings_history.rb): Setting after_save and SettingsController around edit and
  #   plugin (the reason).
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
  module Patches
    module_function

    def apply!
      ::Issue.include(Verification::IssueValue) unless ::Issue < Verification::IssueValue
      ::IssueQuery.prepend(Verification::IssueQueryPatch) unless ::IssueQuery < Verification::IssueQueryPatch
      ::TrackersController.prepend(Verification::TrackersControllerPatch) unless ::TrackersController < Verification::TrackersControllerPatch
      ::Setting.prepend(SettingsHistory::SettingPatch) unless ::Setting < SettingsHistory::SettingPatch
      ::SettingsController.prepend(SettingsHistory::ControllerPatch) unless ::SettingsController < SettingsHistory::ControllerPatch
      ::IssuesHelper.prepend(IssueLinks::HelperPatch) unless ::IssuesHelper < IssueLinks::HelperPatch
      ::ApplicationController.prepend(ExportLog::ControllerPatch) unless ::ApplicationController < ExportLog::ControllerPatch
      ActionView::Base.include(::GkRecordsHelper) unless ActionView::Base.include?(::GkRecordsHelper)
    end
  end
end
