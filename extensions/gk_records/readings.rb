# frozen_string_literal: true

require 'digest'
require 'json'

module GkRecords
  # Readings. One model for imports and syncs; owner plugins make them here, records never reads anything itself.
  # * start! makes the reading. It keeps facts about the files read (name, size, SHA-256), never the files; a source's
  #   manifest is checked against them and kept trimmed to the keys that describe the source;
  # * set! records which fields of an object the reading set (a pointer per field with the source's id for the post,
  #   the source behind the value, when it said it and the SHA-256 of the value, never the value);
  # * finish! stores the counts (added, changed, unchanged, rejected);
  # * origin(obj, field) and label(reading) for the short text beside a field (helper gk_records_origin);
  # * unchanged?(obj, field) tells whether a field still holds the value a reading set, from the digest alone.
  # The source is text until the source register is built.
  #
  # A manifest is JSON with English keys:
  #   { "source", "retrieved", "parts", "srid", "mapping", "sources": [{ "file", "sha256" }],
  #     "files": [{ "file", "sha256", "size", "rows", "kind", "format", "source", "source_ref", "source_time", "url",
  #                 "retrieved" }] }
  # Every file read must be listed under files with its sha256; a manifest without that list is refused.
  module Readings
    class Refused < ArgumentError; end

    COUNT_KEYS = %w[added changed unchanged rejected].freeze
    MANIFEST_TOP = %w[script revision result source dataset version licence retrieved parts srid mapping sources files].freeze
    MANIFEST_ENTRY = %w[file sha256 size rows kind format source source_ref source_time url retrieved].freeze
    SHA = /\A\h{64}\z/

    module_function

    def ready? = ::GkRecordsReading.table_exists? && ::GkRecordsFieldOrigin.table_exists?

    # ------------------------------------------------------------------ manifest.json

    # A manifest as given: a Hash, a JSON text or an uploaded .json file; nil when none. Raises Refused when it is not
    # JSON (the page shows the message).
    def parse_manifest(value)
      return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      return value.to_unsafe_h.to_h.deep_stringify_keys if value.respond_to?(:to_unsafe_h)
      return value.deep_stringify_keys if value.is_a?(Hash)

      text = value.respond_to?(:read) ? value.read : value.to_s
      text = text.to_s.dup.force_encoding('UTF-8')
      text = text.delete_prefix("﻿")
      return nil if text.strip.empty?

      h = JSON.parse(text)
      raise Refused, ::I18n.t(:error_gk_records_reading_manifest_json) unless h.is_a?(Hash)

      h
    rescue JSON::ParserError
      raise Refused, ::I18n.t(:error_gk_records_reading_manifest_json)
    end

    def base_name(path) = path.to_s.split(%r{[\\/]}).last.to_s

    def manifest_files(manifest)
      list = manifest.is_a?(Hash) ? manifest['files'] : nil
      list.is_a?(Array) ? list.grep(Hash) : []
    end

    def manifest_entry(manifest, filename)
      name = base_name(filename).downcase
      manifest_files(manifest).detect { |f| f['file'].present? && base_name(f['file']).downcase == name }
    end

    # A manifest's entry for a file read: listed under files with a sha256 that is the file's. nil without a manifest;
    # Refused when it has no list of files, does not list the file or gives another checksum.
    def check_manifest!(manifest, filename, sha256:)
      return nil unless manifest

      raise Refused, ::I18n.t(:error_gk_records_reading_manifest_files) unless manifest['files'].is_a?(Array)

      name = base_name(filename)
      entry = manifest_entry(manifest, filename)
      want = entry && entry['sha256'].to_s.strip.downcase
      raise Refused, ::I18n.t(:error_gk_records_reading_manifest_unlisted, file: name) unless want&.match?(SHA)
      raise Refused, ::I18n.t(:error_gk_records_reading_sha256, file: name, want: want, got: sha256) unless want == sha256.to_s.downcase

      entry
    end

    # "CSV; semikolon; UTF-8 med BOM" -> "CSV": the short format for the column
    def short_format(text) = text.to_s.split(/[;,(]/).first.to_s.strip.first(20).presence

    def manifest_time(value)
      v = value.to_s.strip
      v.empty? ? nil : Time.zone.parse(v)
    rescue ArgumentError
      nil
    end

    def retrieved_of(manifest, entry = nil) = manifest_time(entry&.dig('retrieved')) || manifest_time(manifest&.dig('retrieved'))

    # A manifest as kept: only the keys that describe the source and its files; anything a script adds about the
    # computer it ran on, its account, its errors or its paths is dropped. A file is kept by its name alone, a url
    # without its query.
    def trim_manifest(manifest)
      return nil unless manifest.is_a?(Hash)

      m = manifest.slice(*MANIFEST_TOP).except('files', 'sources')
      files = manifest_files(manifest).map { |f| trim_entry(f) }
      m['files'] = files if manifest['files'].is_a?(Array)
      sources = manifest['sources'].is_a?(Array) ? manifest['sources'].grep(Hash).map { |s| trim_entry(s.slice('file', 'sha256')) } : nil
      m['sources'] = sources if sources
      m
    end

    def trim_entry(entry)
      e = entry.slice(*MANIFEST_ENTRY)
      e['file'] = base_name(e['file']) if e.key?('file')
      e.delete('sha256') unless e['sha256'].to_s.strip.downcase.match?(SHA)
      e['url'] = e['url'].to_s.split('?').first if e['url'].present?
      e
    end

    # ------------------------------------------------------------------ facts about a file

    # { 'file', 'size', 'sha256' } for bytes; the bytes are not kept
    def file_facts(bytes:, filename:)
      data = bytes.to_s.b
      { 'file' => base_name(filename), 'size' => data.bytesize, 'sha256' => Digest::SHA256.hexdigest(data) }
    end

    # The same for a file on disk, read in pieces (large files)
    def file_facts_path(path)
      { 'file' => base_name(path), 'size' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    # One file as given: facts { file:, size:, sha256: }, { bytes:, filename: } or an uploaded file (read once)
    def facts_of(file)
      if file.is_a?(Hash)
        h = file.transform_keys(&:to_s)
        return file_facts(bytes: h['bytes'], filename: h['filename']) if h.key?('bytes')

        sha = h['sha256'].to_s.strip.downcase
        raise Refused, ::I18n.t(:error_gk_records_reading_manifest_unlisted, file: base_name(h['file'])) unless h['file'].present? && sha.match?(SHA)

        return { 'file' => base_name(h['file']), 'size' => h['size']&.to_i, 'sha256' => sha }
      end

      name = file.respond_to?(:original_filename) ? file.original_filename.to_s : ''
      data = file.read
      file.rewind if file.respond_to?(:rewind)
      file_facts(bytes: data, filename: name)
    end

    # ------------------------------------------------------------------ a value's digest

    # The SHA-256 of a value's canonical text, so a pointer can tell whether a field still holds what a reading set
    # without keeping the value. A string as its bytes (a file's bytes give the file's own checksum); a time in UTC
    # with microseconds; a list as JSON of its sorted texts; a hash as JSON with sorted keys. nil for nil.
    def value_digest(value)
      text = canonical(value)
      text.nil? ? nil : Digest::SHA256.hexdigest(text.b)
    end

    def canonical(value)
      case value
      when nil then nil
      when String then value
      when true, false, Integer, Float, Symbol then value.to_s
      when BigDecimal then value.to_s('F')
      when Time, DateTime then value.to_time.utc.iso8601(6)
      when Date then value.iso8601
      when Array then JSON.generate(value.map(&:to_s).sort)
      when Hash then JSON.generate(value.transform_keys(&:to_s).sort.to_h)
      else value.to_s
      end
    end

    def field_value(obj, field)
      f = field.to_s
      return obj.read_attribute(f) if obj.respond_to?(:has_attribute?) && obj.has_attribute?(f)

      obj.respond_to?(f) ? obj.public_send(f) : nil
    end

    # True when a reading set the field and it still holds that value (from the pointer's digest alone)
    def unchanged?(obj, field)
      t = obj&.id && ready? && Targets.for_object(obj)
      row = t && ::GkRecordsFieldOrigin.find_by(target_type: t.key, target_id: obj.id, field: field.to_s)
      return false unless row&.value_sha256

      row.value_sha256 == value_digest(field_value(obj, field))
    end

    # ------------------------------------------------------------------ making a reading

    # files: the files read, each facts { file:, size:, sha256: }, { bytes:, filename: } or an uploaded file; nil or
    # [] for a reading without files. manifest: a Hash, a JSON text or nil; given, every file must be listed in it
    # with its sha256 (Refused otherwise), and the first file's entry gives source, format, source_ref, source_time and
    # url over the values given. mapping: "name@version" of what turned the files into posts. selection: what the
    # reader chose to read of the files (a Hash such as { by:, path:, values:, labels: }), kept with the reading.
    # Returns the reading.
    def start!(target_type:, source_label:, route: 'file', format: nil, source_time: nil, user: ::User.current, mode: nil,
               source_ref: nil, files: nil, manifest: nil, mapping: nil, retrieved_at: nil, account: nil, source_url: nil,
               made_afterwards: false, read_at: Time.current, origin_reading: nil, rows: nil, origin: nil, selection: nil)
      facts = Array(files).compact.map { |f| facts_of(f) }
      manifest = parse_manifest(manifest)
      entries = facts.map { |f| check_manifest!(manifest, f['file'], sha256: f['sha256']) }
      entry = entries.first
      if entry
        source_label = entry['source'].presence || source_label
        format = short_format(entry['format']) || format
        source_ref = entry['source_ref'].presence || source_ref
        source_time = manifest_time(entry['source_time']) || source_time
        source_url ||= entry['url'].to_s.split('?').first.presence
      end
      source_label = manifest['source'].presence || source_label if manifest && !entry&.dig('source').present?
      retrieved_at ||= retrieved_of(manifest, entry)
      raise Refused, ::I18n.t(:error_gk_records_reading_source) if source_label.to_s.strip.empty?

      person = user.is_a?(::User) && user.logged? ? user : nil
      reading = nil
      ::GkRecordsReading.transaction(requires_new: true) do
        reading = ::GkRecordsReading.create!(
          source_label: source_label.to_s.strip.first(200), source_url: source_url.presence, route: route.to_s,
          format: format.to_s.strip.first(20).upcase.presence, source_ref: source_ref.to_s.strip.first(200).presence,
          source_time: instant(source_time), retrieved_at: instant(retrieved_at),
          read_at: read_at, user_id: person&.id, account: (account || (person ? nil : user&.login.presence)).to_s.first(100).presence,
          mode: (mode.presence || 'once').to_s, rows: rows, target_type: target_type.to_s.first(60).presence,
          files_json: facts.to_json, mapping: mapping.to_s.strip.presence, manifest_json: trim_manifest(manifest)&.to_json,
          selection_json: selection.presence&.to_json,
          made_afterwards: made_afterwards ? true : false, origin_reading_id: origin_reading&.id, created_at: Time.current
        )
        Events.write(reading, 'created', details: { source: reading.source_label, route: reading.route, format: reading.format,
                                                    target_type: reading.target_type, files: facts.map { |f| f['file'] }.presence,
                                                    mapping: reading.mapping }.compact,
                                         user: made_afterwards ? nil : person, origin: origin || default_origin(route))
      end
      reading
    end

    def instant(t) = t.is_a?(Date) && !t.is_a?(DateTime) ? t.in_time_zone : t

    def default_origin(route) = { 'file' => 'import', 'api' => 'synced', 'odbc' => 'synced' }.fetch(route.to_s, 'human')

    # The fields a reading set on an object: one pointer per field. Call it after the object is saved, so the digest is
    # of the value stored. source_id: the source's id for the post (cfarNr, an external id). source, source_time: the
    # source behind the values when the reading has more than one, and when it said them. values: { field => value }
    # over the object's own (a file's bytes, the source's id). digest: false for a reading made in hindsight, which does
    # not know the value it set. at: when the field was set; only_newer: leave a pointer that is newer than at (a
    # reading made in hindsight never moves a pointer a later reading set). Nothing is written for an object that is not
    # a target. selection_key: the key of the reading's selection the post was read under (a municipality's code).
    def set!(reading, obj, fields, source_id: nil, source: nil, source_time: nil, values: nil, digest: true, at: Time.current,
             only_newer: false, selection_key: nil)
      t = Targets.for_object(obj)
      return [] unless t && obj&.id && reading

      given = (values || {}).transform_keys(&:to_s)
      Array(fields).map(&:to_s).reject(&:empty?).uniq.filter_map do |f|
        row = ::GkRecordsFieldOrigin.find_or_initialize_by(target_type: t.key, target_id: obj.id, field: f.first(60))
        next if only_newer && row.persisted? && row.set_at && row.set_at > at

        row.reading_id = reading.id
        row.source_id = source_id.to_s.strip.first(200).presence
        row.source = source.to_s.strip.first(200).presence
        row.source_time = instant(source_time)
        row.value_sha256 = digest ? value_digest(given.key?(f) ? given[f] : field_value(obj, f)) : nil
        row.selection_key = selection_key.to_s.strip.first(60).presence
        row.set_at = at
        row.save!
        row
      end
    end

    # The pointers of many objects at once, for a large reading: one statement per thousand pointers instead of two per
    # pointer. items: [{ obj:, fields:, source_id:, source:, source_time:, values:, digest:, selection_key: }], each as
    # set! takes them (never only_newer). Call it after the objects are saved. Returns how many pointers were written.
    def set_many!(reading, items, at: Time.current)
      return 0 unless reading

      rows = Array(items).flat_map do |it|
        obj = it[:obj]
        t = obj&.id && Targets.for_object(obj)
        next [] unless t

        given = (it[:values] || {}).transform_keys(&:to_s)
        Array(it[:fields]).map(&:to_s).reject(&:empty?).uniq.map do |f|
          { target_type: t.key, target_id: obj.id, field: f.first(60), reading_id: reading.id,
            source_id: it[:source_id].to_s.strip.first(200).presence, source: it[:source].to_s.strip.first(200).presence,
            source_time: instant(it[:source_time]), set_at: at, selection_key: it[:selection_key].to_s.strip.first(60).presence,
            value_sha256: it.fetch(:digest, true) ? value_digest(given.key?(f) ? given[f] : field_value(obj, f)) : nil }
        end
      end
      # one pointer per object and field: the last of a batch wins, as set! called in that order would leave it
      rows = rows.reverse.uniq { |r| [r[:target_type], r[:target_id], r[:field]] }.reverse
      rows.each_slice(1000) { |s| ::GkRecordsFieldOrigin.upsert_all(s, unique_by: %i[target_type target_id field]) }
      rows.size
    end

    # counts: { added:, changed:, unchanged:, rejected: } (other keys are kept too); rows: how many posts were read
    def finish!(reading, counts:, rows: nil)
      c = counts.to_h.transform_keys(&:to_s)
      reading.update_columns(counts_json: c.to_json, rows: rows || c.slice(*COUNT_KEYS).values.sum(&:to_i))
      reading
    end

    # { reading:, source_id:, set_at:, source:, source_time:, value_sha256: } for the reading that last set a field, or nil
    def origin(obj, field)
      return nil unless obj&.id && ready?

      t = Targets.for_object(obj)
      row = t && ::GkRecordsFieldOrigin.includes(:reading).find_by(target_type: t.key, target_id: obj.id, field: field.to_s)
      row && { reading: row.reading, source_id: row.source_id, set_at: row.set_at, source: row.source, source_time: row.source_time,
               value_sha256: row.value_sha256, pointer: row }
    end

    # Every pointer on an object: { field => GkRecordsFieldOrigin }
    def origins(obj)
      t = obj&.id && Targets.for_object(obj)
      return {} unless t && ready?

      ::GkRecordsFieldOrigin.includes(:reading).for_target(t.key, obj.id).index_by(&:field)
    end

    # The object of a target type a reading with this source label gave the source's id to (a second reading of the
    # same file finds the same posts), or nil. mappings: readings by these mappings instead of the label (a manifest
    # may change the label; the mapping says what the source's ids are).
    def find_by_source_id(target_type, source_label, source_id, mappings: nil)
      return nil if source_id.to_s.strip.empty? || !ready?

      t = Targets.find(target_type) or return nil
      rows = ::GkRecordsFieldOrigin.joins(:reading).where(target_type: t.key, source_id: source_id.to_s.strip)
      rows = mappings ? rows.where(gk_records_readings: { mapping: Array(mappings) }) : rows.where(gk_records_readings: { source_label: source_label.to_s })
      row = rows.order(set_at: :desc, id: :desc).first
      row && t.model_class.find_by(id: row.target_id)
    end

    # Many of the source's ids at once (one query for a whole file): { source_id => target_id }, the newest pointer per
    # id, from readings by these mappings
    def ids_by_source_id(target_type, source_ids, mappings:)
      t = ready? && Targets.find(target_type) or return {}
      ids = Array(source_ids).map { |x| x.to_s.strip }.reject(&:empty?).uniq
      return {} if ids.empty?

      ::GkRecordsFieldOrigin.joins(:reading).where(target_type: t.key, source_id: ids)
                            .where(gk_records_readings: { mapping: Array(mappings) })
                            .order(:set_at, :id).pluck(:source_id, :target_id).to_h
    end

    # The posts readings by these mappings read under these keys of their selection: { source_id => target_id }, what
    # a later reading of the same selection should find again
    def pointed(target_type, mappings:, selection_keys:)
      t = ready? && Targets.find(target_type) or return {}

      ::GkRecordsFieldOrigin.joins(:reading).where(target_type: t.key, selection_key: Array(selection_keys).map(&:to_s))
                            .where(gk_records_readings: { mapping: Array(mappings) }).where.not(source_id: nil)
                            .order(:set_at, :id).pluck(:source_id, :target_id).to_h
    end

    # The pointers of many objects at once: { target_id => { field => GkRecordsFieldOrigin } }
    def origins_for(target_type, ids)
      t = ready? && Targets.find(target_type) or return {}

      ::GkRecordsFieldOrigin.includes(:reading).where(target_type: t.key, target_id: Array(ids).compact.uniq)
                            .group_by(&:target_id).transform_values { |rows| rows.index_by(&:field) }
    end

    # True when a pointer holds the digest of this value (a field still as a reading set it)
    def pointer_holds?(pointer, value) = pointer&.value_sha256.present? && pointer.value_sha256 == value_digest(value)

    # "SCB Företagsregistret · CSV · uttag 2026-10-05 · inläst 2026-10-06" in the reader's language; "hämtad" when the
    # source gave no time of its own, "i efterhand" for a reading made in hindsight. pointer: a field's pointer, whose
    # source and source time win over the reading's.
    def label(reading, pointer = nil)
      return '' unless reading

      to_date = ->(t) { ::User.current.time_to_date(t).iso8601 }
      taken = pointer&.source_time || reading.source_time
      parts = [pointer&.source.presence || reading.source_label, reading.format.presence]
      if taken
        parts << ::I18n.t(:label_gk_records_reading_taken, date: to_date.call(taken))
      elsif reading.retrieved_at
        parts << ::I18n.t(:label_gk_records_reading_retrieved, date: to_date.call(reading.retrieved_at))
      end
      parts << ::I18n.t(:label_gk_records_reading_read, date: to_date.call(reading.read_at)) if reading.read_at
      parts << ::I18n.t(:label_gk_records_reading_afterwards) if reading.made_afterwards
      parts.compact.join(' · ')
    end

    # The events the reading's run wrote (owner plugins put reading_id in the details), newest first
    def events(reading, user = ::User.current)
      id = reading.id.to_i
      ::GkRecordsEvent.readable_by(user).where(origin: %w[import synced])
                   .where('details LIKE ? OR details LIKE ?', "%\"reading_id\":#{id},%", "%\"reading_id\":#{id}}%")
                   .order(created_at: :desc, id: :desc)
    end

    # records' own target for readings, so events can be written on them
    def register_target!
      Targets.register('reading', model: 'GkRecordsReading', visible: ->(r, user) { r.visible?(user) }, editable: ->(_r, user) { user.admin? },
                                  label: ->(r) { label(r) }, url: ->(r) { { controller: 'gk_records_readings', action: 'show', id: r.id } })
    end
  end
end
