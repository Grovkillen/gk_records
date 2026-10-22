# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'
require 'stringio'

module GkRecords
  # Läs in dokument. A zip with a document list (CSV) and the files, read into core's Documents of a project and its
  # subprojects, in two steps
  # * preview: nothing is saved but the zip itself, kept as an unattached core attachment of the person who uploaded it
  #   (description KEPT_AS) until the run or the discard, and never longer than KEEP_FOR: each new preview removes the
  #   zips kept longer than that. Per row: the file found or missing, its size and SHA-256, the
  #   target project, the category, the source issue resolved or not, already there (the same SHA-256 on a document of
  #   the same project) and the errors; the files in the zip that no row names. An unknown subproject stops the run; a
  #   row with an error or a missing file is left out and counted as rejected.
  # * run: one reading for the whole list (route file, format ZIP, the zip's name, size and SHA-256 but not the zip, the
  #   list as its manifest with the document each row made), and per row a core Document in the target
  #   project with the file as a core attachment; the document's fields point to the reading with the file name as the
  #   source's id (origin imported, 5.17), its creation is the event created (origin import) with the edition, the date,
  #   the source text and the file's SHA-256 in the details, and a row with a källa gets the link supported_by to the
  #   Källa issue. A row already there is skipped unless the person chose to add it as a new document.
  # Who may: core's add_documents in the project where the import is made and in every target project. Records asks no
  # permission of its own for a reading (an owner makes it on behalf of a person who may do the thing, as people's
  # import does). Nothing is ever deleted: the zip kept for the preview is the only thing removed.
  module DocumentImport
    TARGET = 'document'
    KEPT_AS = 'gk_records_document_import'
    KEEP_FOR = 24.hours
    MAPPING = 'records_document_list@1'
    FIELDS = %w[file title source_text edition date subproject source_issue category].freeze
    REQUIRED = %w[file].freeze
    # What a row does: made (new, again: the file is there but the person chose to add it), skipped (already), left out
    # (missing, error) or stopping the run (unknown_project)
    STATUSES = %w[new again already missing error unknown_project].freeze
    # Headings read without a choice (lower case, without spaces, dots, dashes or underscores); the locale's own
    # headings (label_gk_records_docimp_field_<field>) in every language are read too, so a template made in Swedish is
    # read in an English page and the other way
    HEADINGS = {
      'file' => %w[fil file filnamn filename],
      'title' => %w[vaddetär vaddetar titel title whatitis beskrivning description],
      'source_text' => %w[varifrån varifran varifråndetkom varifrandetkom wherefrom from origin],
      'edition' => %w[utgåva utgava edition version],
      'date' => %w[datum date],
      'subproject' => %w[underprojekt subproject projekt project],
      'source_issue' => %w[källa kalla source sourceissue],
      'category' => %w[kategori category dokumentkategori documentcategory]
    }.freeze
    MAX_ENTRIES = 500
    MAX_ROWS = 1000
    SKIP = %r{(\A|/)(__MACOSX/|\.DS_Store\z|Thumbs\.db\z|desktop\.ini\z)}i
    TEMPLATE_KIND = 'records.document_list_template'
    LINK = 'supported_by'

    # Refused before anything was saved; the message is for the page
    class Refused < ArgumentError; end

    module_function

    def t(key, **opts) = ::I18n.t(key, **opts)

    # A file the person may keep in core: core's own limit per attachment
    def max_bytes = ::Setting.attachment_max_size.to_i.kilobytes

    # ------------------------------------------------------------------ the target

    # A core document is a records target, so its fields can point to a reading, events stand on it and it can be
    # linked (supported_by). Who sees it is core's Document#visible?; who may change and link it core's edit_documents.
    def register_target!
      return if Targets.find(TARGET)

      u = ::Rails.application.routes.url_helpers
      Targets.register(TARGET, model: 'Document', visible: ->(d, user) { d.visible?(user) },
                               editable: ->(d, user) { user.allowed_to?(:edit_documents, d.project) },
                               label: ->(d) { d.title.to_s }, url: ->(d) { u.document_path(d) })
    end

    # ------------------------------------------------------------------ the zip

    # The name of an entry in UTF-8, composed (a zip made on a Mac has the decomposed form)
    def entry_name(raw)
      s = raw.to_s.dup.force_encoding('UTF-8')
      s = raw.to_s.dup.force_encoding('IBM437').encode('UTF-8', invalid: :replace, undef: :replace) unless s.valid_encoding?
      s = s.unicode_normalize(:nfc) rescue s
      s.tr('\\', '/').delete_prefix('./')
    end

    # { name => bytes } of the files in the zip (folders, Mac and Windows litter left out). Raises Refused when it is not
    # a zip, has too many entries or a file larger than core takes.
    def read_zip(bytes)
      require 'zip'
      raise Refused, t(:error_gk_records_docimp_empty_zip) if bytes.to_s.empty?

      limit = max_bytes
      files = {}
      # the central directory (Zip::File, rubyzip 2.3 to 3.x as core ships it), so a zip whose sizes stand after the
      # data (Windows, macOS) is read as well; no file is read beyond the limit, whatever the zip says its size is
      zf = ::Zip::File.open_buffer(::StringIO.new(bytes.to_s.b))
      zf.entries.each do |entry|
        name = entry_name(entry.name)
        next if entry.directory? || name.end_with?('/') || name.match?(SKIP) || name.empty?
        raise Refused, t(:error_gk_records_docimp_too_many, max: MAX_ENTRIES) if files.size >= MAX_ENTRIES

        too_big = t(:error_gk_records_docimp_too_big, file: name, max: ::ActiveSupport::NumberHelper.number_to_human_size(limit))
        raise Refused, too_big if entry.size.to_i > limit

        data = entry.get_input_stream { |io| io.read(limit + 1) }.to_s.b
        raise Refused, too_big if data.bytesize > limit

        files[name] = data
      end
      raise Refused, t(:error_gk_records_docimp_empty_zip) if files.empty?

      files
    rescue ::Zip::Error, ::Zlib::Error, ::EOFError, ::IOError => e
      ::Rails.logger.info("[gk_records] document import: not a zip (#{e.class}: #{e.message})")
      raise Refused, t(:error_gk_records_docimp_not_zip)
    end

    # ------------------------------------------------------------------ the list

    # The text in UTF-8: a byte order mark goes; what is not UTF-8 is read as Windows-1252 (Excel)
    def decode(bytes)
      s = bytes.to_s.dup.force_encoding('BINARY')
      s = s.byteslice(3..) if s.start_with?("\xEF\xBB\xBF".b)
      u = s.dup.force_encoding('UTF-8')
      u.valid_encoding? ? u : s.force_encoding('Windows-1252').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    def norm(h)
      s = h.to_s.strip.downcase
      s = s.unicode_normalize(:nfc) rescue s
      s.gsub(/[\s.\-_]/, '')
    end

    def field_labels(f)
      ::I18n.available_locales.filter_map { |loc| ::I18n.t("label_gk_records_docimp_field_#{f}", locale: loc, default: '').presence }
    end

    # { field => column index } from the headings
    def mapping(headings)
      normed = headings.map { |h| norm(h) }
      FIELDS.each_with_object({}) do |f, out|
        names = (HEADINGS[f] + field_labels(f)).map { |n| norm(n) }
        i = normed.each_index.find { |j| names.include?(normed[j]) && !out.value?(j) }
        out[f] = i if i
      end
    end

    # [headings, rows] of a CSV (semicolon or comma, whichever the heading line has more of); nil when it cannot be read
    def parse_csv(bytes)
      text = decode(bytes)
      first = text.each_line.first.to_s
      sep = first.count(';') >= first.count(',') ? ';' : ','
      table = ::CSV.parse(text, col_sep: sep, liberal_parsing: true).reject { |r| r.compact.all? { |c| c.to_s.strip.empty? } }
      return nil if table.empty?

      [table.first.map { |h| h.to_s.strip }, table.drop(1)]
    rescue ::CSV::MalformedCSVError
      nil
    end

    # The document list among the files: a CSV whose headings have the column fil. [name, headings, rows, mapping];
    # raises Refused when there is none or more than one
    def find_list(files)
      found = files.keys.select { |n| File.extname(n).casecmp?('.csv') }.sort.filter_map do |n|
        h, rows = parse_csv(files[n])
        next unless h

        m = mapping(h)
        m.key?('file') ? [n, h, rows, m] : nil
      end
      raise Refused, t(:error_gk_records_docimp_no_list) if found.empty?
      raise Refused, t(:error_gk_records_docimp_many_lists, files: found.map(&:first).join(', ')) if found.size > 1

      found.first
    end

    # ------------------------------------------------------------------ the preview

    # The projects a row may name: the project itself and its subprojects that are not archived
    def projects_under(project)
      # read the project again: its lft and rgt in memory are stale when subprojects were made after it was loaded,
      # and the nested set then finds no descendants
      fresh = ::Project.find_by(id: project.id) || project
      fresh.self_and_descendants.where.not(status: ::Project::STATUS_ARCHIVED).to_a
    end

    def project_for(cell, project, under)
      v = cell.to_s.strip
      return project if v.empty?

      d = v.downcase
      under.detect { |p| p.identifier.to_s.downcase == d } || under.detect { |p| p.name.to_s.strip.downcase == d }
    end

    def category_for(cell)
      v = cell.to_s.strip
      return ::DocumentCategory.default if v.empty?

      ::DocumentCategory.shared.active.detect { |c| c.name.to_s.strip.casecmp?(v) }
    end

    # The issue a källa cell names (#123 or 123), or [nil, error]
    def source_issue_for(cell, user)
      v = cell.to_s.strip
      return [nil, nil] if v.empty?

      id = v[/\A#?\s*(\d+)\z/, 1]
      return [nil, t(:error_gk_records_docimp_source_form, value: v)] unless id

      kind = Kinds.find(:link, LINK)
      return [nil, t(:error_gk_records_docimp_no_register)] unless kind

      issue = ::Issue.visible(user).find_by(id: id.to_i)
      return [nil, t(:error_gk_records_docimp_source_missing, id: id)] unless issue
      return [nil, t(:error_gk_records_docimp_source_kind, id: id, kind: kind.label)] unless kind.allows?('issue') && kind.fits?(TARGET, 'issue')

      refused = kind.refusal(nil, issue)
      refused ? [nil, refused] : [issue, nil]
    end

    # The zip entry a fil cell names: the same path, or the only file with that name in any folder (case aside)
    def entry_for(cell, files)
      v = entry_name(cell.to_s.strip)
      return nil if v.empty?

      files.keys.detect { |n| n == v } || files.keys.detect { |n| n.casecmp?(v) } ||
        (m = files.keys.select { |n| File.basename(n).casecmp?(File.basename(v)) }).size == 1 && m.first || nil
    end

    # The documents in a project with an attachment of the same SHA-256
    def already(project, sha)
      ids = ::Attachment.where(container_type: 'Document', digest: sha).pluck(:container_id)
      ids.empty? ? [] : ::Document.where(id: ids, project_id: project.id).order(:id).to_a
    end

    # Everything the page shows, and what the run does. add_again: the list's line numbers the person chose to add as a
    # new document although the file is there. Nothing is saved.
    # { list:, files:, rows: [ { 'line', 'file', 'entry', 'bytes', 'sha256', 'title', 'source_text', 'edition', 'date',
    #   'project' (Project), 'category' (DocumentCategory), 'issue' (Issue), 'already' ([Document]), 'status', 'errors' } ],
    #   extra: [names], stop: true when a subproject is unknown, unread: [headings no field reads], counts: }
    def preview(project, bytes, user: ::User.current, add_again: [])
      files = read_zip(bytes)
      list, headings, table, map = find_list(files)
      raise Refused, t(:error_gk_records_docimp_list_empty, file: list) if table.empty?
      raise Refused, t(:error_gk_records_docimp_too_many_rows, max: MAX_ROWS) if table.size > MAX_ROWS

      again = Array(add_again).map(&:to_i)
      under = projects_under(project)
      cell = ->(r, f) { map.key?(f) ? r[map[f]].to_s.strip : '' }
      seen = {}
      rows = table.each_with_index.map do |r, i|
        line = i + 2
        row = { 'line' => line, 'errors' => [] }
        FIELDS.each { |f| row[f] = cell.call(r, f) }
        row['entry'] = entry_for(row['file'], files)
        if row['entry']
          data = files[row['entry']]
          row['bytes'] = data.bytesize
          row['sha256'] = Digest::SHA256.hexdigest(data)
          ext = File.extname(row['entry']).delete_prefix('.')
          row['errors'] << t(:error_attachment_extension_not_allowed, extension: ext) unless ::Attachment.valid_extension?(ext)
        end
        target = project_for(row['subproject'], project, under)
        row['project'] = target
        if target
          if !target.module_enabled?(:documents)
            row['errors'] << t(:error_gk_records_docimp_no_module, project: target.name)
          elsif !user.allowed_to?(:add_documents, target)
            row['errors'] << t(:error_gk_records_docimp_not_allowed, project: target.name)
          end
        end
        row['category'] = category_for(row['category'])
        row['errors'] << t(:error_gk_records_docimp_category, value: cell.call(r, 'category').presence || '-') unless row['category']
        row['issue'], err = source_issue_for(row['source_issue'], user)
        row['errors'] << err if err
        row['already'] = target && row['sha256'] ? already(target, row['sha256']) : []
        twin = target && row['sha256'] ? seen[[target.id, row['sha256']]] : nil
        row['errors'].unshift(t(:error_gk_records_docimp_no_file_cell)) if row['file'].empty?
        row['errors'].unshift(t(:error_gk_records_docimp_unknown_project, value: row['subproject'], project: project.name)) unless target
        row['status'] =
          if target.nil? then 'unknown_project'
          elsif row['file'].empty? then 'error'
          elsif row['entry'].nil? then 'missing'
          elsif row['errors'].any? then 'error'
          elsif (row['already'].any? || twin) && !again.include?(line) then 'already'
          elsif row['already'].any? || twin then 'again'
          else 'new'
          end
        row['twin_line'] = twin if twin
        seen[[target.id, row['sha256']]] ||= line if target && row['sha256'] && %w[new again].include?(row['status'])
        row
      end
      named = rows.filter_map { |x| x['entry'] }
      extra = files.keys.reject { |n| n == list || named.include?(n) }.sort
      used = map.values
      { list: list, files: files, rows: rows, extra: extra, stop: rows.any? { |x| x['status'] == 'unknown_project' },
        unread: headings.each_with_index.reject { |_h, i| used.include?(i) }.map { |h, i| h.presence || (i + 1).to_s },
        counts: rows.group_by { |x| x['status'] }.transform_values(&:size) }
    end

    def made?(row) = %w[new again].include?(row['status'])

    # ------------------------------------------------------------------ the zip kept until the run

    # The zip as an unattached core attachment of the person, marked as this import's for the project; the zips any
    # preview kept longer than KEEP_FOR go first
    def keep!(project, bytes, filename, user)
      sweep!
      att = ::Attachment.new(file: bytes.to_s.b, author: user)
      att.filename = filename.presence || 'dokument.zip'
      att.content_type = 'application/zip'
      att.description = "#{KEPT_AS}:#{project.id}"
      raise Refused, att.errors.full_messages.join(', ') unless att.save

      att
    end

    # The person's kept zip by its token, for this project only
    def kept(project, token, user)
      att = ::Attachment.find_by_token(token.to_s)
      att && att.container_id.nil? && att.author_id == user.id && att.description == "#{KEPT_AS}:#{project.id}" ? att : nil
    end

    # The person's zips kept for the project, newest first
    def pending(project, user)
      ::Attachment.where(container_id: nil, author_id: user.id, description: "#{KEPT_AS}:#{project.id}").order(created_on: :desc).to_a
    end

    def bytes_of(att) = File.binread(att.diskfile)

    # Discard: the kept zip goes (nothing else was saved)
    def discard!(att)
      att&.destroy
    end

    # The zips kept longer than KEEP_FOR, of every person and project, go. Returns how many.
    def sweep!(now: Time.current)
      old = ::Attachment.where(container_id: nil).where('description LIKE ?', "#{KEPT_AS}:%").where('created_on < ?', now - KEEP_FOR).to_a
      old.each(&:destroy)
      old.size
    end

    # ------------------------------------------------------------------ the run

    # The run. source_label: the reading's source (the list's name when empty). Raises Refused when a subproject is
    # unknown or no row would make a document; everything in one transaction. Returns [reading, made documents].
    def run!(project, att, user: ::User.current, source_label: nil, add_again: [])
      bytes = bytes_of(att)
      pv = preview(project, bytes, user: user, add_again: add_again)
      raise Refused, t(:error_gk_records_docimp_stopped) if pv[:stop]

      todo = pv[:rows].select { |r| made?(r) }
      raise Refused, t(:error_gk_records_docimp_nothing) if todo.empty?

      label = source_label.to_s.strip.presence || File.basename(pv[:list], '.*')
      reading = nil
      made = []
      ::ActiveRecord::Base.transaction do
        reading = Readings.start!(target_type: TARGET, source_label: label, route: 'file', format: 'zip', user: user, mode: 'once',
                                  files: [{ bytes: bytes, filename: att.filename }], mapping: MAPPING, rows: pv[:rows].size,
                                  origin: 'import')
        todo.each do |row|
          doc = make_document!(reading, row, pv[:files][row['entry']], user)
          row['document_id'] = doc.id
          made << doc
        end
        Readings.finish!(reading, counts: { 'added' => made.size, 'unchanged' => pv[:rows].count { |r| r['status'] == 'already' },
                                            'rejected' => pv[:rows].count { |r| %w[missing error].include?(r['status']) } },
                                  rows: pv[:rows].size)
        reading.update_columns(manifest_json: manifest(pv, label).to_json)
        att.destroy
      end
      [reading, made]
    end

    # The description: what the list says beside the title, as a list core's formatters both read
    def description_for(row)
      lines = [%w[source_text label_gk_records_docimp_field_source_text], %w[edition label_gk_records_docimp_field_edition],
               %w[date label_gk_records_docimp_field_date]].filter_map do |f, key|
        row[f].present? ? "* #{t(key).sub(/\A./, &:upcase)}: #{row[f]}" : nil
      end
      lines.join("\n")
    end

    # One document: the file as its attachment, the pointers to the reading, the event and the link to the source
    def make_document!(reading, row, data, user)
      target = row['project']
      doc = ::Document.new(project: target, category: row['category'])
      doc.title = (row['title'].presence || File.basename(row['entry'])).to_s.first(255)
      doc.description = description_for(row)
      doc.save!
      a = ::Attachment.new(file: data.to_s.b, author: user)
      a.filename = File.basename(row['entry'])
      a.content_type = ::Redmine::MimeType.of(a.filename) || 'application/octet-stream'
      a.container = doc
      raise ::ActiveRecord::RecordInvalid, a unless a.save

      sid = row['entry']
      # the file's digest is its bytes', the same as the attachment's
      Readings.set!(reading, doc, %w[title description category_id file], source_id: sid, values: { 'file' => data })
      details = { 'reading_id' => reading.id, 'file' => sid, 'bytes' => a.filesize, 'sha256' => a.digest, 'title' => doc.title,
                  'source_text' => row['source_text'].presence, 'edition' => row['edition'].presence, 'date' => row['date'].presence,
                  'category' => row['category']&.name, 'source_issue' => row['issue']&.id, 'again' => row['status'] == 'again' || nil }.compact
      Events.write(doc, 'created', details: details, user: user, origin: 'import', project: target)
      # answer 4: the link Stöds av to the Källa issue. Made by the import, not by hand: it carries the origin import and
      # no text (a citation's text is a place in the source, optional; the reason place records.link_manual is for links
      # made by hand). Should the kind ask a reason all the same, the reading names why.
      if row['issue']
        kind = Kinds.find(:link, LINK)
        make = lambda do |why|
          ::GkRecordsLink.create!(source_type: TARGET, source_id: doc.id, target_type: 'issue', target_id: row['issue'].id, kind: LINK,
                               reason: why, user_id: user&.id, origin: 'import')
        end
        if kind && kind.manual && !kind.citation && Reasons.required?('records.link_manual')
          # A system text, kept as its key and shown in the reader's language (SystemText); the reading is named by its
          # source and format, which read the same in every language
          SystemText.as_reason(:text_gk_records_docimp_link_reason, 'reading' => [reading.source_label, reading.format.presence].compact.join(', ')) { |why| make.call(why) }
        else
          make.call(nil)
        end
      end
      doc
    end

    # The list as the reading's manifest, with what each row did. Its rows are the list's, not the files read (the
    # reading's files are the zip).
    def manifest(pv, label)
      { 'script' => 'gk_records document_import', 'source' => label, 'list' => pv[:list],
        'rows' => pv[:rows].map do |r|
          { 'line' => r['line'], 'file' => r['entry'] || r['file'], 'size' => r['bytes'], 'sha256' => r['sha256'], 'title' => r['title'].presence,
            'from' => r['source_text'].presence, 'edition' => r['edition'].presence, 'date' => r['date'].presence,
            'subproject' => r['project']&.identifier, 'source_issue' => r['issue']&.id, 'category' => r['category']&.name,
            'outcome' => r['status'], 'document' => r['document_id'] }.compact
        end,
        'other_files' => pv[:extra] }
    end

    # ------------------------------------------------------------------ the template

    # The template's headings are the import's own fields in the reader's language (so it never drifts from what is
    # read); UTF-8 with a byte order mark and semicolons; the name is revisions' one rule when revisions is there
    def template_csv
      ::Redmine::Export::CSV.generate(encoding: 'UTF-8', field_separator: ';') do |csv|
        csv << FIELDS.map { |f| t("label_gk_records_docimp_field_#{f}") }
      end
    end

    def template_name
      return ::GkRevisions::Names.file_name(TEMPLATE_KIND) if defined?(::GkRevisions::Names)

      "#{t(:label_gk_records_docimp_template_file)}.csv"
    end

    def declare_names!
      return unless defined?(::GkRevisions::Names)

      ::GkRevisions::Names.register(TEMPLATE_KIND, plugin: :gk_records, label_key: :label_gk_records_name_document_list_template, ext: 'csv')
    end
  end

  # The document page shows where a read-in document came from (the reading, and the source it cites); the Dokument tab
  # gets the link Läs in dokument for whoever may add documents. Core has no hook on those pages, so the line is
  # rendered at the end of the content and moved in place by a small script (without it, it stays at the end).
  class DocumentImportHooks < Redmine::Hook::ViewListener
    def view_layouts_base_content(context = {})
      c = context[:controller]
      return '' unless c.is_a?(::DocumentsController)

      view = context[:hook_caller]
      case c.action_name
      when 'show'
        doc = c.instance_variable_get(:@document)
        doc ? view.render(partial: 'gk_records_document_imports/origin', locals: { document: doc }) : ''
      when 'index'
        project = c.instance_variable_get(:@project)
        project && User.current.allowed_to?(:add_documents, project) ? view.render(partial: 'gk_records_document_imports/link', locals: { project: project }) : ''
      else ''
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_records] document import hook: #{e.class} #{e.message}")
      ''
    end
  end
end
