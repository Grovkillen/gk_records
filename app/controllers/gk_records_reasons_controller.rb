# frozen_string_literal: true

# Administration > Skäl: the mode for the installation and per place, per plugin, with the default beside it; the
# places where the text is the act itself or a rule decides are listed apart, without a choice. Every change is an
# event with the reason.
class GkRecordsReasonsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  # administrators only, as core's require_admin; an OAuth token also needs the read scope (the list) or the manage
  # scope (a change)
  before_action :require_admin_scope
  accept_api_auth :index, :update

  def index
    r = GkRecords::Reasons
    respond_to do |format|
      format.html do
        @places = r.by_plugin
        @fixed = r.by_plugin(fixed: true)
      end
      format.json do
        render json: { installation: r.installation_mode,
                       places: r.all.values.map { |p| { key: p.key, plugin: p.plugin, name: p.label, default: p.default, own: p.fixed ? nil : r.own_mode(p.key),
                                                         mode: r.mode(p.key), admin: p.admin, fixed: p.fixed } } }
      end
    end
  end

  # key ('*' for the installation), mode, reason
  def update
    r = GkRecords::Reasons
    key = params[:key].to_s
    return render_404 unless key == r::ALL || (r.find(key) && !r.find(key).fixed)
    # the installation's Av, Valfritt or Krävs locks the places (records_1022-SID-01)
    return fail_with(l(:error_gk_records_reason_locked), key) if key != r::ALL && r.locked?

    check = r.check('records.reason_modes', params[:reason])
    return fail_with(check.error, key) unless check.ok

    r.set_mode!(key, params[:mode].to_s, reason: check.text)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_records_reasons_path(anchor: anchor(key)) }
      format.json { render json: { key: key, mode: key == r::ALL ? r.installation_mode : r.mode(key) } }
    end
  rescue ArgumentError
    fail_with(l(:error_gk_records_reason_mode), key)
  end

  private

  def require_admin_scope
    return false unless require_login

    s = GkRecords::ApiScope
    return true if s.admin_allows?(User.current, action_name == 'index' ? s::READ : s::MANAGE)

    render_403
    false
  end

  def anchor(key) = key == GkRecords::Reasons::ALL ? 'r-all' : "r-#{key.tr('.', '-')}"

  def fail_with(message, key)
    respond_to do |format|
      format.html { flash[:error] = message; redirect_to gk_records_reasons_path(anchor: anchor(key)) }
      format.json { render json: { errors: [message] }, status: :unprocessable_entity }
    end
  end
end
