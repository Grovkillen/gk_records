# frozen_string_literal: true

class GkRecordsVerificationsController < GkRecordsBaseController
  # the declared function records.verification: while it is off the address answers as if it were not there
  before_action -> { render_404 unless GkRecords::Verification.feature? }
  before_action :find_target

  # The row's script asks as JSON: { ok: true, html: the row drawn anew } or { ok: false, message:, code: }
  # (code open_review: the page asks whether the open review is taken back, and sends withdraw=1 to go on). Without
  # the script the form posts and the page comes back as before.
  def update
    ok, error, code = GkRecords::Verification.change(@target, params[:status], user: User.current, reason: params[:reason],
                                                                              withdraw: params[:withdraw].to_s == '1')
    if request.format.json? || request.xhr?
      back = params[:back_url].to_s.start_with?('/') ? params[:back_url].to_s : request.referer.to_s
      if ok
        html = render_to_string(partial: 'gk_records/verification', formats: [:html], locals: { obj: @target.reload, back_url: back })
        return render(json: { ok: true, html: html })
      end

      # the question about an open review is no error: 200, so that the browser logs nothing; a refusal is 422
      return render(json: { ok: false, message: error, code: code }, status: code == GkRecords::Verification::OPEN_REVIEW ? :ok : :unprocessable_entity)
    end
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
