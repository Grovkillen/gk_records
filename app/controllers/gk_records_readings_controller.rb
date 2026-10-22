# frozen_string_literal: true

#   GET /gk_records/readings[.json]      the list (administrators)
#   GET /gk_records/readings/:id[.json]  one reading
class GkRecordsReadingsController < ApplicationController
  self.main_menu = false
  before_action :require_login
  before_action :require_admin, only: %i[index]
  before_action :find_reading, only: %i[show]
  accept_api_auth :index, :show
  helper :gk_records
  # the pages are hidden while the function is off (records_1021, "Dölja sidor och menyer"); the API answers as before
  before_action -> { render_404 unless GkRecords::Features.on?('readings') }, if: -> { request.format.html? }

  def index
    scope = GkRecordsReading.sorted.includes(:user)
    scope = scope.where(target_type: params[:target_type].to_s) if params[:target_type].present?
    # Arel's matches: ILIKE on PostgreSQL, LIKE elsewhere (uppdrag 116)
    scope = scope.where(GkRecordsReading.arel_table[:source_label].matches("%#{GkRecordsReading.sanitize_sql_like(params[:source].to_s.strip)}%")) if params[:source].present?
    @readings = scope.limit((params[:limit] || 200).to_i.clamp(1, 1000)).to_a
    respond_to do |format|
      format.html { render layout: 'admin' }
      format.api do
        gids = GkRecords::Identity.gids_for(GkRecords::Identity.key_for('GkRecordsReading'), @readings.map(&:id))
        render json: { readings: @readings.map { |r| reading_json(r, gids[r.id]) } }
      end
    end
  end

  def show
    @events = GkRecords::Readings.events(@reading).limit(500).to_a
    @origins = @reading.field_origins.order(:target_type, :target_id, :field).to_a
    respond_to do |format|
      format.html { render layout: (User.current.admin? ? 'admin' : 'base') }
      format.api do
        render json: { reading: reading_json(@reading).merge(manifest: @reading.manifest,
                                                             fields: @origins.map { |o| { target: "#{o.target_type}:#{o.target_id}", field: o.field, source_id: o.source_id, set_at: o.set_at, source: o.source, source_time: o.source_time } },
                                                             events: @events.map(&:as_api_json)) }
      end
    end
  end

  private

  def find_reading
    @reading = GkRecordsReading.find_by(id: params[:id])
    return render_404 unless @reading

    deny_access unless @reading.visible?
  end

  # Gid, the reading's global id (given by the list, otherwise looked up here)
  def reading_json(r, gid = nil)
    { id: r.id, gid: gid || GkRecords::Identity.for(r), label: GkRecords::Readings.label(r), source_label: r.source_label, source_url: r.source_url, route: r.route, format: r.format,
      source_ref: r.source_ref, source_time: r.source_time, read_at: r.read_at, account: r.account, mode: r.mode, rows: r.rows,
      counts: r.counts, target_type: r.target_type, made_afterwards: r.made_afterwards, origin_reading_id: r.origin_reading_id,
      files: r.files, mapping: r.mapping, retrieved_at: r.retrieved_at, selection: r.selection }
      .merge(GkRecords::Visibility.api_user(:user_id, r.user_id, r.user))
  end
end
