# frozen_string_literal: true

# The event log: a target's events for whoever may see the target; a project's events (the project module Händelser,
# 1.01.000) for whoever has Se händelser there; under Administration everything for administrators, and for others the
# events of the projects where they have Se händelser (the events without a project only administrators see).
# Filters: target, kind, user, from, to. CSV with the same rows (GkRecords::EventsCsv).
class GkRecordsEventsController < GkRecordsBaseController
  accept_api_auth :index
  helper :gk_records
  # no project menu above the log, also in the administration (records_1021-SID-37), as on Readings and Reasons; a
  # project's tab has the project menu (core's current_menu takes the project's)
  self.main_menu = false
  menu_item :gk_records_events
  # the page is hidden while the function is off (records_1021, "Dölja sidor och menyer"); the API answers as before
  before_action -> { render_404 unless GkRecords::Features.on?('events') }, if: -> { request.format.html? || request.format.csv? }
  before_action :find_events_project

  PERMISSION = :gk_records_view_events

  def index
    if params[:target].present?
      find_target
      return if performed?

      # id breaks the tie, and keeps the order in the hour that comes twice when summer time ends (the column has no zone)
      scope = GkRecordsEvent.readable_by(User.current).includes(:user, :reason_note).order(created_at: :desc, id: :desc)
                            .for_target(@target_def.key, @target.id)
    else
      # 1.01.000: the project's tab, or the log under Administration, by the one rule (GkRecordsEvent.log_for)
      scope = GkRecordsEvent.log_for(User.current, project: @project)
      return deny_access if scope.nil?
    end
    scope = scope.where(kind: params[:kind]) if params[:kind].present?
    # a person the reader may not see gives no hits, so the filter cannot tell who did what (GkRecords::Visibility)
    if params[:user_id].present?
      ids = GkRecords::Visibility.visible_user_ids(Array(params[:user_id]))
      scope = ids.empty? ? scope.none : scope.where(user_id: ids)
    end
    scope = scope.where(created_at: day_start(Date.parse(params[:from]))..) if params[:from].present?
    scope = scope.where(created_at: ..day_end(Date.parse(params[:to]))) if params[:to].present?
    # the page's Rensa shows only when a filter differs from the defaults (none of them given) (records_1021-SID-29)
    @filtered = %i[kind user_id from to].any? { |k| params[k].present? }
    respond_to do |format|
      format.html do
        @events = scope.limit((params[:limit] || 200).to_i.clamp(1, 1000))
        render layout: (User.current.admin? && @project.nil? ? 'admin' : 'base')
      end
      # 1.01.000: as core's issue export, at most Setting.issues_export_limit rows
      format.csv do
        send_data GkRecords::EventsCsv.generate(scope.limit(Setting.issues_export_limit.to_i)), type: 'text/csv; header=present',
                                                                                                 filename: GkRecords::EventsCsv.file_name(project: @project)
      end
      format.api do
        @events = scope.limit((params[:limit] || 200).to_i.clamp(1, 1000))
        render json: { events: @events.map(&:as_api_json) }
      end
    end
  rescue Date::Error
    render_error status: 422
  end

  private

  # The project's tab: Se händelser in the project (the module on); administrators always
  def find_events_project
    return if params[:project_id].blank?

    @project = Project.find(params[:project_id])
    deny_access unless User.current.allowed_to?(PERMISSION, @project)
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
