# frozen_string_literal: true

# Administration > Skäl: the mode for the installation and per place, per plugin, with the default beside it; the
# places where the text is the act itself or a rule decides are listed apart, without a choice. The page is one form
# (GK GUI Stuff's form page): every changed mode goes in one save with one reason (update_all). One mode at a time
# (update) stays for the API. Every change is an event with the reason. While the place records.reason_modes is off
# no reason is offered and none is kept, on the page and in both ways of the API: a reason sent then is dropped.
class GkRecordsReasonsController < ApplicationController
  include GkRecords::Gate::Controller # core's 404 without GK GUI Stuff (gate.rb)
  layout 'admin'
  self.main_menu = false
  # administrators only, as core's require_admin; an OAuth token also needs the read scope (the list) or the manage
  # scope (a change)
  before_action :require_admin_scope
  accept_api_auth :index, :update, :update_all
  # the form page's helpers are GK GUI Stuff's; without it every action is core's 404 (the gate)
  helper :gk_gui_stuff_form_page if defined?(::GkGuiStuffFormPageHelper)

  PLACE = 'records.reason_modes'

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
    # the installation's Av, Valfritt or Krävs locks the places
    return fail_with(l(:error_gk_records_reason_locked), key) if key != r::ALL && r.locked?

    check = r.check(PLACE, params[:reason])
    return fail_with(check.error, key) unless check.ok

    r.set_mode!(key, params[:mode].to_s, reason: check.text)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_records_reasons_path(anchor: anchor(key)) }
      format.json { render json: { key: key, mode: key == r::ALL ? r.installation_mode : r.mode(key) } }
    end
  rescue ArgumentError
    fail_with(l(:error_gk_records_reason_mode), key)
  end

  # installation: the installation's mode, modes: { place => mode }, and the form's one reason. Only what differs from
  # what is stored is changed, all of it or nothing. A place whose mode is not sent (its radio buttons are switched
  # off while the installation locks it) keeps what is stored. The places' modes may come in the same save as
  # Varje ställe för sig, which opens them.
  def update_all
    r = GkRecords::Reasons
    # what is stored is read from the table, never from what this process remembers: another process may just have saved
    r.forget!
    given = params[:modes]
    given = given.to_unsafe_h if given.respond_to?(:to_unsafe_h)
    changes = (given.is_a?(Hash) ? given : {}).each_with_object({}) do |(key, mode), out|
      p = r.find(key)
      return fail_with(l(:error_gk_records_reason_mode), key.to_s) unless p && !p.fixed && (r::MODES + [r::INHERIT]).include?(mode.to_s)

      out[p.key] = mode.to_s if mode.to_s != r.own_mode(p.key)
    end
    all = params[:installation].to_s
    return fail_with(l(:error_gk_records_reason_mode), r::ALL) unless all.blank? || (r::MODES + [r::PLACES]).include?(all)

    # the installation's Av, Valfritt or Krävs locks the places, as it will stand after this save: a save that opens
    # the places (Varje ställe för sig) may carry their changes, and one that locks them may carry none: all of it
    # is refused, also where the places stood open before the save. That save has words of its own, since the stored
    # mode may already be Varje ställe för sig
    locks = all.present? ? r::MODES.include?(all) : r.locked?
    if changes.any? && locks
      return fail_with(l(all.present? ? :error_gk_records_reason_locked_save : :error_gk_records_reason_locked), changes.keys.first)
    end

    if all.present? && all != r.installation_mode
      # the installation's mode last; first when it opens the places, so that each place's event says what holds then
      changes = all == r::PLACES ? { r::ALL => all }.merge(changes) : changes.merge(r::ALL => all)
    end
    if changes.empty?
      return respond_to do |format|
        format.html { flash[:notice] = l(:text_gk_records_reasons_nothing_to_save); redirect_to gk_records_reasons_path }
        format.json { render json: { changed: [] } }
      end
    end

    check = r.check(PLACE, params[:reason])
    return fail_with(check.error, changes.keys.first) unless check.ok

    # the check's own answer: no text while the place is off, whatever was sent, as in update
    reason = check.text
    ::GkRecordsReasonMode.transaction { changes.each { |key, mode| r.set_mode!(key, mode, reason: reason) } }
    r.forget!
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_records_reasons_path }
      format.json do
        render json: { changed: changes.keys, installation: r.installation_mode,
                       places: (changes.keys - [r::ALL]).map { |k| { key: k, own: r.own_mode(k), mode: r.mode(k) } } }
      end
    end
  rescue ArgumentError
    r.forget!
    fail_with(l(:error_gk_records_reason_mode), r::ALL)
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
