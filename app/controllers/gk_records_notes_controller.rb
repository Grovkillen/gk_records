# frozen_string_literal: true

# Notes: list (JSON), write, correct (a new note with the link corrects) and void with a reason. Never edit.
class GkRecordsNotesController < GkRecordsBaseController
  accept_api_auth :index, :create, :void
  before_action :find_target, only: [:index, :create]
  before_action :require_editable, only: [:create]
  before_action :find_note, only: [:void]

  def index
    notes = GkRecordsNote.for_target(@target_def.key, @target.id).order(:created_at, :id)
    # target_gid, the global id of the thing the notes are on
    render json: { notes: notes.map(&:as_api_json), target_gid: GkRecords::Identity.for(@target) }
  end

  def create
    note = GkRecordsNote.new(target_type: @target_def.key, target_id: @target.id, kind: params[:kind].presence || 'comment',
                          body: params[:body].to_s.strip, user_id: User.current.id, origin: 'human')
    parent = params[:parent_id].present? && GkRecordsNote.for_target(@target_def.key, @target.id).find_by(id: params[:parent_id])
    note.parent_id = parent.id if parent
    corrected = params[:corrects_id].present? && GkRecordsNote.for_target(@target_def.key, @target.id).find_by(id: params[:corrects_id])
    # Both or neither: a correction whose link is refused takes the new note back with it, and says why
    saved = false
    errors = []
    GkRecordsNote.transaction do
      saved = note.save
      errors = note.errors.full_messages
      if saved && corrected
        link = GkRecordsLink.create(source_type: 'gk_records_note', source_id: note.id, target_type: 'gk_records_note',
                                 target_id: corrected.id, kind: 'corrects', user_id: User.current.id)
        saved = link.persisted?
        errors = link.errors.full_messages unless saved
      end
      raise ActiveRecord::Rollback unless saved
    end
    respond_to do |format|
      format.html do
        # core shows a flash as HTML: the messages are escaped
        saved ? flash[:notice] = l(:notice_gk_records_note_saved) : flash[:error] = ERB::Util.html_escape(errors.join(', '))
        back_to_target(saved ? "gk-records-note-#{note.id}" : 'gk-records')
      end
      format.api { saved ? render(json: note.as_api_json, status: :created) : render(json: { errors: errors }, status: :unprocessable_entity) }
    end
  end

  # Void with a reason: the note stays, folded, with who, when and why
  def void
    # The place records.note_void decides whether the reason is required
    check = GkRecords::Reasons.check('records.note_void', params[:reason])
    ok = check.ok && !@note.voided?
    @note.void!(User.current, check.text) if ok
    respond_to do |format|
      format.html do
        ok ? flash[:notice] = l(:notice_gk_records_note_voided) : flash[:error] = (check.error || l(:error_gk_records_void_reason))
        back_to_target("gk-records-note-#{@note.id}")
      end
      format.api { ok ? render(json: @note.reload.as_api_json) : render(json: { errors: [check.error || l(:error_gk_records_void_reason)] }, status: :unprocessable_entity) }
    end
  end

  private

  def find_note
    @note = GkRecordsNote.find_by(id: params[:id])
    return render_404 unless @note

    find_target("#{@note.target_type}:#{@note.target_id}")
    return if performed?

    deny_access unless GkRecords::Targets.editable?(@target) && (@note.user_id == User.current.id || User.current.admin?)
  end
end
