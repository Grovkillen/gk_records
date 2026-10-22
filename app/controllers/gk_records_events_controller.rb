# frozen_string_literal: true

# The event log: a target's events for whoever may see the target, the whole log (audit) for admins and the
# global permission gk_records_view_events. Filters: target, kind, user, from, to.
class GkRecordsEventsController < GkRecordsBaseController
  accept_api_auth :index
  helper :gk_records
  # no project menu above the log, also in the administration (records_1021-SID-37), as on Readings and Reasons
  self.main_menu = false
  # the page is hidden while the function is off (records_1021, "Dölja sidor och menyer"); the API answers as before
  before_action -> { render_404 unless GkRecords::Features.on?('events') }, if: -> { request.format.html? }

  def index
    # id breaks the tie, and keeps the order in the hour that comes twice when summer time ends (the column has no zone)
    scope = GkRecordsEvent.readable_by(User.current).includes(:user, :reason_note).order(created_at: :desc, id: :desc)
    if params[:target].present?
      find_target
      return if performed?

      scope = scope.for_target(@target_def.key, @target.id)
    elsif !(User.current.admin? || User.current.allowed_to_globally?(:gk_records_view_events))
      return deny_access
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
    @events = scope.limit((params[:limit] || 200).to_i.clamp(1, 1000))
    respond_to do |format|
      format.html { render layout: (User.current.admin? ? 'admin' : 'base') }
      format.api { render json: { events: @events.map(&:as_api_json) } }
    end
  rescue Date::Error
    render_error status: 422
  end
end
