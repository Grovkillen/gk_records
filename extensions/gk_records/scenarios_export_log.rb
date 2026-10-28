# frozen_string_literal: true

require 'digest'
require 'json'

module GkRecords
  module Scenarios
    # The export log in scenarios (ExportLog).
    # * step records_permissions (order 150): the permissions the roles get (records: permissions: - { role: manager,
    #   may: [view_exports] }); a role made before the permission existed has not got it from "all"
    # * expectation records_export_logged: s4, by:, as:, equals:, print: (see below)
    # * expectation records_export_manifest: zip
    module_function

    def register_export_log!
      if defined?(::GkScenarios::Steps)
        ::GkScenarios::Steps.register('records_permissions', plugin: :gk_records, order: 150) do |ctx|
          Array((ctx.scenario.data['records'] || {})['permissions']).each do |row|
            role = ctx.get(:role, row['role'])
            missing = Array(row['may']).map { |m| :"gk_records_#{m}" } - role.permissions
            missing.each { |perm| role.add_permission!(perm) }
            ctx.note(:rec_permission, row['role'], role, missing.any?)
          end
        end
      end

      # An export of the scenario's issue (records_export_logged: s4) by the scenario's user in by, or with print: true
      # the issue's page printed (ExportLog.printed! from its path, as the browser's beacon gives it), and whether the
      # scenario's user in as sees the event (GkRecordsEvent.readable_by: the permission gk_records_view_exports in the
      # issue's project). Written in a transaction that is rolled back, so no event stays.
      ::GkScenarios::Expect.register('records_export_logged') do |ctx, e|
        issue = ::GkScenarios::Expect.issue_for(ctx, e['records_export_logged'].to_s)
        actor = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'] || e['as']))
        viewer = e['as'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
        next({ 'ok' => false, 'want' => 'issue, by, as', 'got' => issue ? 'no user in by or as' : 'no issue' }) unless issue && actor && viewer
        next({ 'ok' => false, 'want' => 'equals: true | false', 'got' => '-' }) unless e.key?('equals')
        next({ 'ok' => false, 'want' => 'export_log on', 'got' => 'off' }) unless ExportLog.on?

        result = nil
        ::GkRecordsEvent.transaction(requires_new: true) do
          last_id = ::GkRecordsEvent.maximum(:id).to_i
          ctx.as(actor) do
            if e['print']
              ExportLog.printed!("#{Redmine::Utils.relative_url_root}/issues/#{issue.id}", Struct.new(:remote_ip).new('127.0.0.1'))
            else
              ExportLog.write(issue, 'exported', { 'file' => 'scenario.csv', 'format' => 'csv', 'rows' => 1, 'ip' => '127.0.0.1' }, issue.project)
            end
          end
          kind = e['print'] ? 'printed' : 'exported'
          event = ::GkRecordsEvent.where('id > ?', last_id).where(kind: kind).order(:id).last
          if event.nil? || event.target_type != 'issue' || event.target_id != issue.id || event.project_id != issue.project_id
            result = { 'ok' => false, 'want' => "#{kind} on the issue in its project", 'got' => event ? "#{event.target_type}:#{event.target_id} p#{event.project_id}" : 'no event' }
          else
            got = ::GkRecordsEvent.readable_by(viewer).exists?(event.id)
            want = e['equals'].to_s == 'true'
            result = { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
          end
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => 'event', 'got' => '-' }
      end

      # The export log with a manifest: records_export_manifest: zip. A made-up CSV is wrapped as an export asked for
      # with with_manifest=1 would be: the zip holds the file under its name and manifest.json, whose file entry names
      # the file with its SHA-256 and size and the instance as source, in the keys records reads and without the
      # account; the request without the choice is not wrapped. Nothing is written.
      ::GkScenarios::Expect.register('records_export_manifest') do |_ctx, e|
        next({ 'ok' => false, 'want' => 'records_export_manifest: zip', 'got' => e['records_export_manifest'].to_s }) unless e['records_export_manifest'].to_s == 'zip'

        require 'zip'
        data = "Nr;Ämne\n1;Prov\n".b
        name = 'scenario_export_manifest.csv'
        checks = []
        begin
          man = ExportLog.manifest_doc(file: name, data: data, kind: 'core.issues', source_ref: 'issues#index', url: '/issues.csv', format: 'CSV',
                                       rows: 1)
          zip = ExportLog.zip_with_manifest(name, data, man)
          entries = {}
          ::Zip::InputStream.open(::StringIO.new(zip)) do |zis|
            while (entry = zis.get_next_entry)
              entries[entry.name] = zis.read
            end
          end
          read = JSON.parse(entries['manifest.json'].to_s)
          f = Array(read['files']).first || {}
          sum = Digest::SHA256.hexdigest(data)
          checks << ['a zip with the file and manifest.json', entries.keys.sort == [name, 'manifest.json'].sort]
          checks << ['the file as it was', entries[name].to_s.b == data]
          checks << ['manifest names the file', f['file'] == name && f['size'] == data.bytesize]
          checks << ['manifest has its SHA-256', f['sha256'] == sum]
          checks << ['the instance as source', f['source'] == ExportLog.instance_name && read['source'] == ExportLog.instance_name && read['plugin'] == 'gk_records']
          checks << ['the keys records reads, no account', read['retrieved'].present? && f['source_ref'] == 'issues#index' && !f.key?('konto') && !f.key?('account')]
          checks << ['zip name', ExportLog.zip_name('issues_2026-10-06.csv') == 'issues_2026-10-06.zip']
          fake = Struct.new(:controller_path, :action_name, :params).new('issues', 'index', ActionController::Parameters.new({}))
          checks << ['without the choice nothing changes', !ExportLog.manifest_wanted?(fake)]
          fake.params = ActionController::Parameters.new('with_manifest' => '1')
          checks << ['with the choice', ExportLog.manifest_wanted?(fake) == ExportLog.on?]
        rescue StandardError => ex
          checks << ["#{ex.class}: #{ex.message}"[0, 200], false]
        end
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
      end
    end
  end
end
