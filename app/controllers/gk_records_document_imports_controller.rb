# frozen_string_literal: true

# Läs in dokument: a zip with a document list read into core's Documents of a project and its subprojects. For those
# with core's add_documents in the project (and, row by row, in the project a row goes to). The zip is kept as the
# person's unattached core attachment until the run or the discard.
#   GET  /projects/:project_id/document_import            the upload, the template and the person's kept zips
#   POST /projects/:project_id/document_import            the zip read and kept, then the preview
#   GET  /projects/:project_id/document_import/preview    the preview (file: the kept zip's token)
#   POST /projects/:project_id/document_import/run        the run (file, source_label, add_again[]: line numbers)
#   POST /projects/:project_id/document_import/discard    the kept zip goes
#   GET  /gk_records/document_import/template            the document list's template (CSV)
class GkRecordsDocumentImportsController < ApplicationController
  menu_item :documents
  before_action :require_login
  before_action :find_project_by_project_id, except: :template
  before_action :require_add_documents, except: :template
  before_action :find_kept, only: %i[preview run discard]
  helper :gk_records
  helper :attachments

  def new
    @pending = GkRecords::DocumentImport.pending(@project, User.current)
  end

  def create
    file = params[:zip]
    raise GkRecords::DocumentImport::Refused, l(:error_gk_records_docimp_choose_zip) unless file.respond_to?(:read)

    bytes = file.read.to_s.b
    GkRecords::DocumentImport.preview(@project, bytes, user: User.current) # refused here when it cannot be read
    att = GkRecords::DocumentImport.keep!(@project, bytes, file.original_filename.to_s, User.current)
    redirect_to gk_records_document_import_preview_path(@project, file: att.token)
  rescue GkRecords::DocumentImport::Refused => e
    flash.now[:error] = e.message
    @pending = GkRecords::DocumentImport.pending(@project, User.current)
    render :new, status: 422
  end

  def preview
    @preview = GkRecords::DocumentImport.preview(@project, GkRecords::DocumentImport.bytes_of(@kept), user: User.current,
                                                                                                       add_again: params[:add_again])
  rescue GkRecords::DocumentImport::Refused => e
    @error = e.message
  end

  def run
    reading, made = GkRecords::DocumentImport.run!(@project, @kept, user: User.current, source_label: params[:source_label],
                                                                     add_again: params[:add_again])
    flash[:notice] = l(:notice_gk_records_docimp_done, count: made.size)
    redirect_to gk_records_reading_path(reading)
  rescue GkRecords::DocumentImport::Refused, ActiveRecord::RecordInvalid => e
    flash[:error] = e.message
    redirect_to gk_records_document_import_preview_path(@project, file: @kept.token, add_again: params[:add_again])
  end

  def discard
    GkRecords::DocumentImport.discard!(@kept)
    flash[:notice] = l(:notice_gk_records_docimp_discarded)
    redirect_to gk_records_document_import_path(@project)
  end

  def template
    send_data GkRecords::DocumentImport.template_csv, type: 'text/csv; header=present', filename: GkRecords::DocumentImport.template_name
  end

  private

  def require_add_documents
    deny_access unless User.current.allowed_to?(:add_documents, @project)
  end

  def find_kept
    @kept = GkRecords::DocumentImport.kept(@project, params[:file], User.current)
    render_404 unless @kept
  end
end
