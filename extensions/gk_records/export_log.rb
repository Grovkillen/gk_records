# frozen_string_literal: true

require 'digest'

module GkRecords
  # export_log
  # * every export that leaves the system (core's, by core_stuff's list of core's exports, GkCoreStuff::Exports, and
  #   the plugins', named by revisions' rule) and every attachment downloaded is an event on what it is about (the
  #   issue, the wiki page, the project; the exporter herself for what has no project): who, when, the file's name, its
  #   SHA-256, its size, the query and its filters and how many rows, the format, and the IP address;
  # * a print asked for in the browser (Ctrl+P or the menu) is an event too, "utskrift begärd": the browser says that
  #   printing starts, never whether paper came out, and a screenshot or a browser without scripts is not seen;
  # * the events ask the permission gk_records_view_exports (Se exporter och utskrifter) in their project, since that
  #   someone exported is itself sensitive.
  # Images shown inside a text (the browser fetches them as images) and thumbnails are not downloads and not logged.
  # * A named export asked for with with_manifest=1 is sent as a zip with the file and manifest.json (plugin and
  #   version, start, end, result, the instance as source, retrieved, and per file: file, kind, source, url, format,
  #   source_ref (the query or the object), source_time, retrieved, rows, size, sha256; never the computer or the
  #   account); the zip is logged with its own SHA-256, the file's in the details. Offered as a check box in core's CSV
  #   dialog and a link "med manifest" beside the other formats (script).
  #   Without the choice nothing changes.
  # The setting export_log (on for a new installation) switches it all off; the events already written stay.
  module ExportLog
    KINDS = %w[exported attachment_downloaded printed].freeze
    PERMISSION = :gk_records_view_exports
    SUM_MAX = 50 * 1_048_576 # a file on disk larger than this is not read for its checksum

    class << self
      def on?
        s = ::Setting.plugin_gk_records
        (s.is_a?(Hash) ? s.transform_keys(&:to_s)['export_log'] : nil).to_s != '0'
      rescue StandardError
        true
      end

      # The targets the events may stand on that records has not (the project, a wiki page), and the kinds; after the
      # plugins that load before records have registered theirs
      def register!
        u = Rails.application.routes.url_helpers
        unless Targets.find('project')
          Targets.register('project', model: 'Project', visible: ->(p, user) { p.visible?(user) }, editable: ->(_p, _u) { false },
                                      label: ->(p) { p.name }, url: ->(p) { u.project_path(p) })
        end
        unless Targets.find('wiki_page')
          Targets.register('wiki_page', model: 'WikiPage', visible: ->(w, user) { w.visible?(user) }, editable: ->(_w, _u) { false },
                                        label: ->(w) { w.pretty_title }, url: ->(w) { u.project_wiki_page_path(w.wiki.project, w.title) })
        end
        KINDS.each do |k|
          Kinds.register_event(k, plugin: :gk_records, label_key: "label_gk_records_event_#{k}", permission: PERMISSION)
        end
      end

      # ------------------------------------------------------------------ what a request sent

      # core's export the controller's action sends (core_stuff's list), or nil
      def core_kind(c) = defined?(::GkCoreStuff::Exports) ? ::GkCoreStuff::Exports.kind_of(c) : nil

      # Which kind of event a sent file is, or nil: core's exports, the plugins' (named by revisions' rule in this
      # request), attachments downloaded
      def kind_for(c)
        route = "#{c.controller_path}##{c.action_name}"
        return 'attachment_downloaded' if %w[attachments#download attachments#download_all].include?(route) && c.request.headers['Sec-Fetch-Dest'] != 'image'
        return 'exported' if core_kind(c)
        return 'exported' if Thread.current[:gk_revisions_named_export]

        nil
      end

      def filename_of(c)
        cd = c.response.headers['Content-Disposition'].to_s
        name = cd[/filename\*=UTF-8''([^;]+)/i, 1]
        name ? CGI.unescape(name) : cd[/filename="([^"]+)"/i, 1]
      end

      # What the file is about, and its project
      def target_of(c)
        att = c.instance_variable_get(:@attachment)
        container = att&.container || c.instance_variable_get(:@container)
        obj = case container
              when ::Issue, ::WikiPage then container
              when ::Project then container
              else
                c.instance_variable_get(:@issue) || (c.controller_path == 'wiki' && c.action_name == 'show' ? c.instance_variable_get(:@page) : nil)
              end
        obj ||= container.respond_to?(:project) ? container.project : nil
        obj ||= c.instance_variable_get(:@project)
        obj ||= ::User.current if ::User.current.logged?
        project = case obj
                  when ::Project then obj
                  when ::WikiPage then obj.wiki&.project
                  else obj.respond_to?(:project) ? obj.project : nil
                  end
        [obj, project]
      end

      # ------------------------------------------------------------------ an export with a manifest

      MANIFEST_PARAM = 'with_manifest'

      # The request asks for a manifest on a named export (core's list or a plugin's name from revisions)
      def manifest_wanted?(c)
        c.params[MANIFEST_PARAM].to_s == '1' && on? && kind_for(c) == 'exported'
      rescue StandardError
        false
      end

      def instance_name
        host = Setting.host_name.to_s.presence
        [Setting.app_title.to_s.presence || 'Redmine', host && "(#{host})"].compact.join(' ')
      end

      def plugin_version
        Redmine::Plugin.find(:gk_records).version.to_s
      rescue StandardError
        ''
      end

      # manifest.json in the keys GK Records reads (files with file, size and sha256): one file, the instance as its
      # source; neither the computer nor the account is written
      def manifest_doc(file:, data:, kind:, source_ref:, url:, format:, rows:, started: Time.current)
        now = Time.current
        bytes = data.to_s.b
        { 'script' => 'gk_records export_log', 'plugin' => 'gk_records', 'revision' => plugin_version,
          'start' => started.iso8601, 'end' => now.iso8601, 'result' => 'ok', 'source' => instance_name, 'retrieved' => now.iso8601,
          'files' => [{ 'file' => file, 'kind' => kind.to_s, 'source' => instance_name, 'url' => url.to_s, 'format' => format.to_s,
                        'source_ref' => source_ref.to_s, 'source_time' => now.iso8601, 'retrieved' => now.iso8601,
                        'rows' => rows, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes) }],
          'errors' => [] }
      end

      # The zip: the file under its own name, and manifest.json
      def zip_with_manifest(file, data, manifest)
        require 'zip'
        io = ::Zip::OutputStream.write_buffer(::StringIO.new(+'')) do |zos|
          zos.put_next_entry(file)
          zos.write(data.to_s.b)
          zos.put_next_entry('manifest.json')
          zos.write(JSON.pretty_generate(manifest))
        end
        io.string.b
      end

      def zip_name(file) = "#{File.basename(file.to_s, '.*').presence || 'export'}.zip"

      # What the query or the object is, for source_ref: "issues#index, query 12 Mina ärenden" or "issues#show, issue 7"
      def source_ref_of(c)
        q = c.instance_variable_get(:@query)
        obj, = target_of(c)
        parts = ["#{c.controller_path}##{c.action_name}"]
        parts << "query #{q.id} #{q.name}".strip if q&.id
        parts << "#{obj.class.name.underscore} #{obj.id}" if obj && !obj.is_a?(::User) && !(q && obj.is_a?(::Project))
        parts << "project #{obj.identifier}" if obj.is_a?(::Project) && q
        parts.join(', ')
      end

      # [zip, options for core's send_data, the file sent inside { name:, sha256:, bytes:, data: }]; the file's name is
      # revisions' when it names core's exports, whichever of the two patches runs first
      def wrap(c, data, options)
        inner_opts = defined?(::GkRevisions::CoreExports) ? ::GkRevisions::CoreExports.rename(c, options) : options
        name = inner_opts[:filename].presence || "#{c.controller_path}.#{c.request.format&.symbol || 'dat'}"
        url = c.request.original_url.sub(/([?&])#{MANIFEST_PARAM}=1(&|\z)/) { Regexp.last_match(2).empty? ? '' : Regexp.last_match(1) }
        fmt = c.request.format&.symbol&.to_s
        rows = fmt == 'csv' ? csv_rows(data) : nil
        manifest = manifest_doc(file: name, data: data, kind: Thread.current[:gk_revisions_named_export] || core_kind(c),
                                source_ref: source_ref_of(c), url: url, format: fmt.to_s.upcase, rows: rows,
                                started: c.instance_variable_get(:@gk_records_started) || Time.current)
        zip = zip_with_manifest(name, data, manifest)
        opts = options.merge(filename: zip_name(name), type: 'application/zip', disposition: 'attachment')
        [zip, opts, { name: name, sha256: manifest['files'].first['sha256'], bytes: manifest['files'].first['size'], data: data }]
      end

      def details_of(c, sent)
        q = c.instance_variable_get(:@query)
        count = %i[@issue_count @entry_count @count].lazy.map { |v| c.instance_variable_get(v) }.find { |v| v.is_a?(Integer) }
        count ||= %i[@issues @entries @members @users].lazy.map { |v| c.instance_variable_get(v) }.find { |v| v.respond_to?(:size) }&.size
        att = c.instance_variable_get(:@attachment)
        d = { 'file' => filename_of(c), 'format' => c.request.format&.symbol&.to_s.presence&.then { |f| f == 'html' ? nil : f }, 'route' => "#{c.controller_path}##{c.action_name}",
              'export' => Thread.current[:gk_revisions_named_export] || core_kind(c),
              'sha256' => sent[:sha256], 'bytes' => sent[:bytes], 'ip' => c.request.remote_ip }
        count ||= csv_rows(sent[:inner] ? sent[:inner][:data] : sent[:data]) if d['format'] == 'csv'
        d['manifest'] = sent[:inner].except(:data).transform_keys(&:to_s) if sent[:inner]

        if q
          d['query'] = { 'id' => q.id, 'name' => (q.name.presence if q.id), 'filters' => q.filters,
                         'columns' => q.respond_to?(:column_names) ? Array(q.column_names).map(&:to_s) : nil }.compact
        end
        d['rows'] = count if count
        d['attachment'] = { 'id' => att.id, 'filename' => att.filename } if att
        d.compact
      end

      # The rows of a CSV core made (its list is a local variable there): the records less the header, read with
      # core's separator in the exporter's language; quotes and line breaks are the same bytes in every encoding
      def csv_rows(data)
        return nil unless data.is_a?(String)

        require 'csv'
        [::CSV.parse(data.b, col_sep: ::I18n.t(:general_csv_separator, default: ','), liberal_parsing: true).size - 1, 0].max
      rescue StandardError
        nil
      end

      # The checksum and the size of what was sent: the data, the attachment's own digest (SHA-256), or the file
      def measure(c, sent)
        if sent[:data]
          s = sent[:data].to_s
          { sha256: Digest::SHA256.hexdigest(s), bytes: s.bytesize }
        elsif sent[:path]
          att = c.instance_variable_get(:@attachment)
          size = File.size?(sent[:path].to_s)
          sum = att && att.digest.to_s.size == 64 ? att.digest : (size && size <= SUM_MAX ? Digest::SHA256.file(sent[:path].to_s).hexdigest : nil)
          { sha256: sum, bytes: size }
        else
          body = c.response.body.to_s
          { sha256: Digest::SHA256.hexdigest(body), bytes: body.bytesize }
        end
      rescue StandardError
        {}
      end

      def log!(c, sent)
        return unless on? && sent

        kind = kind_for(c) or return
        obj, project = target_of(c)
        return unless obj

        write(obj, kind, details_of(c, sent.merge(measure(c, sent))), project)
      rescue StandardError => e
        Rails.logger.warn("[gk_records] export not logged (#{e.class}: #{e.message})")
      end

      def write(obj, kind, details, project)
        Events.write(obj, kind, details: details, user: ::User.current.logged? ? ::User.current : nil, origin: 'human', project: project)
      end

      # ------------------------------------------------------------------ a print asked for in the browser

      # The page printed, from its path: an issue, a wiki page or a project the reader may see; otherwise the reader
      def printed!(path, request)
        return false unless on? && ::User.current.logged?

        r = Rails.application.routes.recognize_path(path.to_s.sub(%r{\A#{Regexp.escape(Redmine::Utils.relative_url_root.to_s)}}, ''))
        project = r[:project_id] ? ::Project.visible.find_by(identifier: r[:project_id]) : nil
        obj = case "#{r[:controller]}##{r[:action]}"
              when 'issues#show' then ::Issue.visible.find_by(id: r[:id])
              when 'wiki#show' then project&.wiki&.find_page(r[:id].presence || project.wiki.start_page)
              when 'projects#show' then ::Project.visible.find_by(identifier: r[:id])
              end
        obj = nil if obj.is_a?(::WikiPage) && !obj.visible?
        project ||= obj.is_a?(::Project) ? obj : obj&.project
        obj ||= project || ::User.current
        write(obj, 'printed', { 'page' => path.to_s[0, 500], 'ip' => request.remote_ip }, project.is_a?(::Project) ? project : nil)
        true
      rescue ActionController::RoutingError, StandardError => e
        Rails.logger.warn("[gk_records] print not logged (#{e.class}: #{e.message})")
        false
      end
    end

    # ApplicationController: what a request sends is noted, and logged when the response is done
    # (around process_action, not callbacks: a controller that built its own chain of callbacks before this was added
    # would never run one added to ApplicationController afterwards)
    module ControllerPatch
      def process_action(*args)
        Thread.current[:gk_revisions_named_export] = nil
        @gk_records_sent = nil
        @gk_records_started = Time.current

        result = super
        gk_records_wrap_rendered!
        ExportLog.log!(self, @gk_records_sent) if @gk_records_sent
        result
      ensure
        Thread.current[:gk_revisions_named_export] = nil
      end

      private

      # with_manifest=1 on a named export sends a zip with the file and manifest.json instead
      def send_data(data, options = {})
        if data.is_a?(String) && ExportLog.manifest_wanted?(self)
          zip, opts, inner = ExportLog.wrap(self, data, options)
          @gk_records_sent = { data: zip, inner: inner }
          return super(zip, opts)
        end
        @gk_records_sent = { data: data }
        super
      end

      def send_file(path, options = {})
        @gk_records_sent = { path: path }
        super
      end

      # core's send_data and send_file call this too: what they noted stays
      def send_file_headers!(options)
        @gk_records_sent ||= { rendered: true }
        super
      end

      # core's PDFs of a list, an issue and the wiki set their headers with send_file_headers! and render a template,
      # never through send_data: with with_manifest=1 the rendered file is wrapped in the same zip once it is drawn
      def gk_records_wrap_rendered!
        sent = @gk_records_sent
        return unless sent && sent[:rendered] && !sent[:inner] && response.status == 200 && ExportLog.manifest_wanted?(self)

        data = response.body.to_s
        return if data.empty?

        zip, opts, inner = ExportLog.wrap(self, data, { filename: ExportLog.filename_of(self) })
        response.body = zip
        response.content_type = opts[:type]
        response.headers['Content-Disposition'] = ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: opts[:filename])
        response.headers.delete('Content-Length')
        @gk_records_sent = { data: zip, inner: inner }
      end
    end
  end

  # With the export log on, the script that tells the server when the page is printed and the choice "med manifest"
  # where exports are offered (only for one logged in)
  class ExportLogHooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(_context = {})
      return '' unless ExportLog.on? && User.current.logged?

      url = "#{Redmine::Utils.relative_url_root}/gk_records/printed"
      out = content_tag(:meta, nil, id: 'gk-records-export-print', name: 'gk-records-export-print', 'data-url': url)
      out += javascript_include_tag('gk_records_export_print', plugin: 'gk_records', defer: true)
      # "med manifest" in core's CSV dialog and beside the other formats
      out += content_tag(:meta, nil, id: 'gk-records-export-manifest', name: 'gk-records-export-manifest', 'data-label': l(:label_gk_records_with_manifest),
                                     'data-title': l(:text_gk_records_with_manifest))
      out + javascript_include_tag('gk_records_export_manifest', plugin: 'gk_records', defer: true)
    rescue StandardError => e
      Rails.logger.error("[gk_records] export log scripts not loaded: #{e.class}: #{e.message}")
      ''
    end
  end
end
