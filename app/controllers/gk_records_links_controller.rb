# frozen_string_literal: true

# Links between two registered targets (or notes). Voided, never deleted. Seen from one thing (links_view): its
# page of links (grouped by kind and direction, filters, voided ones behind a switch, and adding by hand for the
# kinds that are open for it), and the same grouping as the content of the tab on an issue.
class GkRecordsLinksController < GkRecordsBaseController
  accept_api_auth :index, :create, :void
  helper :gk_records
  # the most hits a search looks through before they are paged
  MAX_HITS = 1000
  # the page and the tab are hidden while the function is off (records_1021, "Dölja sidor och menyer"); the API and
  # the links the owner plugins write go on as before
  before_action -> { render_404 unless GkRecords::Features.on?('links') }, only: [:page, :tab]
  before_action :find_target, only: [:index, :create, :page, :tab]

  def index
    links = GkRecordsLink.touching(@target_def.key, @target.id).order(:created_at, :id)
    # target_gid, the global id of the thing the links touch
    render json: { links: links.map(&:as_api_json), target_gid: GkRecords::Identity.for(@target) }
  end

  def page
    load_links
    # Only the kinds this thing may be one end of (Kind#offered_on?, sources)
    @manual_kinds = GkRecords::Kinds.of(:link).select(&:manual).select { |k| k.offered_on?(@target_def.key) }
    # The kind chosen (the first when none is), whose targets decide what may be searched for
    @add_kind = @manual_kinds.detect { |k| k.key == params[:add_kind] } || @manual_kinds.first
    if params[:q].present?
      # many hits are paged as core's lists are, with its per page choice
      found = candidates
      @hit_count = found.size
      @hit_pages = Paginator.new(@hit_count, per_page_option, params['page'])
      @candidates = found[@hit_pages.offset, @hit_pages.per_page] || []
    end
    @project = @target.project if @target.is_a?(::Issue)
  end

  # The tab on the issue page: fetched by core's getRemoteTab when the tab is opened
  def tab
    return render_error(status: 422) unless request.xhr?

    load_links
    render partial: 'gk_records_links/groups', locals: { compact: true }
  end

  # By hand only for the kinds that are open for it (with a short reason); every other kind is made by the plugin
  # that owns it, in code. What may not be linked (itself, twice, a circle) is the model's to say (link_semantics).
  def create
    return deny_access unless GkRecords::Targets.linkable?(@target)

    kind = GkRecords::Kinds.find(:link, params[:kind].presence || 'manual')
    return render_error(status: 422, message: l(:error_gk_records_link_kind)) unless kind&.manual

    other = GkRecords::Targets.resolve(params[:other])
    return render_404 unless other && GkRecords::Targets.visible?(other[1])

    # A citation's text is the place in the source (locator, or reason in the API), optional and never a reason
    text = if kind.citation
             (params[:locator].presence || params[:reason]).to_s.strip.presence
           else
             GkRecords::Reasons.check('records.link_manual', params[:reason]).text
           end
    link = GkRecordsLink.new(source_type: @target_def.key, source_id: @target.id, target_type: other[0].key, target_id: other[1].id,
                          kind: kind.key, reason: text, user_id: User.current.id)
    saved = link.save
    respond_to do |format|
      format.html { saved ? flash[:notice] = l(:notice_gk_records_link_saved) : flash[:error] = ERB::Util.html_escape(link.errors.full_messages.join(', ')); back_to_page }
      format.api { saved ? render(json: link.as_api_json, status: :created) : render(json: { errors: link.errors.full_messages }, status: :unprocessable_entity) }
    end
  end

  # From the page of either end, by whoever may link that thing
  def void
    link = GkRecordsLink.find_by(id: params[:id])
    return render_404 unless link

    find_target(params[:target].presence || "#{link.source_type}:#{link.source_id}")
    return if performed?
    return render_404 unless [[link.source_type, link.source_id], [link.target_type, link.target_id]].include?([@target_def.key, @target.id])
    return deny_access unless GkRecords::Targets.linkable?(@target)

    link.void!(User.current) unless link.voided_at
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_gk_records_link_voided); back_to_page }
      format.api { render json: link.reload.as_api_json }
    end
  end

  private

  # With the sources too, this thing being the source (Kind#fits?)
  def add_type_allowed?(kind, key)
    kind.nil? || kind.fits?(@target_def.key, key)
  end
  helper_method :add_type_allowed?

  def back_to_page
    redirect_to gk_records_links_page_path(target: "#{@target_def.key}:#{@target.id}")
  end

  def load_links
    @linkable = GkRecords::Targets.linkable?(@target)
    scope = GkRecordsLink.touching(@target_def.key, @target.id).includes(:user).order(:created_at, :id)
    @all_count = scope.active.count
    @voided_count = scope.where.not(voided_at: nil).count
    scope = scope.active unless params[:voided] == '1'
    @links = scope.to_a
    @kinds_here = @links.map(&:kind).uniq
    @things_here = @links.map { |k| GkRecords::Links.other(k, @target_def.key, @target.id).first }.uniq
    @links = @links.select { |k| k.kind == params[:kind] } if params[:kind].present?
    @links = @links.select { |k| GkRecords::Links.other(k, @target_def.key, @target.id).first == params[:with] } if params[:with].present?
  end

  # What the person searched for, among what she may see: an issue by its number or its title, anything else by its name
  def candidates
    t = GkRecords::Targets.find(params[:add_type])
    return [] unless t && add_type_allowed?(@add_kind, t.key)

    q = params[:q].to_s.strip
    found = if t.model == 'Issue' && q.match?(/\A#?\d+\z/)
              [::Issue.visible.find_by(id: q.delete('#').to_i)].compact
            elsif t.model == 'Issue'
              # the title, any case, newest first
              ::Issue.visible.where('LOWER(issues.subject) LIKE ?', "%#{::ActiveRecord::Base.sanitize_sql_like(q.downcase)}%").order(id: :desc).limit(MAX_HITS).to_a
            else
              t.model_class.limit(MAX_HITS).to_a.select { |o| GkRecords::Targets.visible?(o) && GkRecords::Targets.label(o).downcase.include?(q.downcase) }
            end
    found = found.reject { |o| o == @target }
    # Only what the kind's own check lets through (a source of one tracker)
    @add_kind&.check ? found.select { |o| @add_kind.refusal(@target, o).nil? } : found
  end
end
