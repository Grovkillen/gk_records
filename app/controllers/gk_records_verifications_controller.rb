# frozen_string_literal: true

class GkRecordsVerificationsController < GkRecordsBaseController
  # the declared function records.verification: while it is off the address answers as if it were not there
  before_action -> { render_404 unless GkRecords::Verification.feature? }
  before_action :find_target

  def update
    ok, error = GkRecords::Verification.change(@target, params[:status], user: User.current, reason: params[:reason])
    if ok
      flash[:notice] = l(:notice_gk_records_verification_set)
    else
      flash[:error] = error
    end
    url = GkRecords::Targets.url(@target)
    anchor = @target.is_a?(Issue) ? 'gk-records-verification' : nil
    redirect_back_or_default(url.is_a?(Hash) ? url_for(anchor ? url.merge(anchor: anchor) : url) : (url || home_url))
  end
end
