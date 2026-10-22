# frozen_string_literal: true

# The assessments of one thing: read only (an assessment is made by the part of the system that owns the kind,
# through GkRecords::Assessments.record). The page, the tab on an issue, and JSON.
class GkRecordsAssessmentsController < GkRecordsBaseController
  accept_api_auth :index
  helper :gk_records
  # the page and the tab are hidden while the function is off (records_1021, "Dölja sidor och menyer"); the API answers
  before_action -> { render_404 unless GkRecords::Features.on?('assessments') }, only: [:page, :tab]
  before_action :find_target

  # Each assessment's gid, and target_gid, the global id of the thing assessed
  def index
    list = scope.to_a
    gids = GkRecords::Identity.gids_for(GkRecords::Identity.key_for('GkRecordsAssessment'), list.map(&:id))
    render json: { assessments: list.map { |a| a.as_api_json(User.current, gid: gids[a.id]) }, target_gid: GkRecords::Identity.for(@target) }
  end

  def page
    @assessments = scope.to_a
    @project = @target.project if @target.is_a?(::Issue)
  end

  # The tab on the issue page: fetched by core's getRemoteTab when the tab is opened
  def tab
    return render_error(status: 422) unless request.xhr?

    @assessments = scope.to_a
    render partial: 'gk_records_assessments/table', locals: { compact: true }
  end

  private

  def scope
    GkRecordsAssessment.for_target(@target_def.key, @target.id).includes(:user, :supersedes).newest_first
  end
end
