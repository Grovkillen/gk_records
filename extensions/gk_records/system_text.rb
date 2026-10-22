# frozen_string_literal: true

require 'digest'
require 'json'

module GkRecords
  # The system's own texts as a key. A note, an event's reason or a link's reason that the system writes (not a person)
  # keeps its locale key and its values (text_key, text_values) beside the text in the instance's language, and is shown
  # in the reader's language as the text stood when it was written.
  #
  # The texts are a matrix, key by locale, and each cell is revised on its own: gk_records_text_revisions has one row
  # per change of one cell (key, locale, the template as the locale file had it, its SHA-256, valid_from). A row is
  # added only when the cell's text differs from the cell's latest row, and rows are never changed or deleted
  # (Grundmodellen: history is never rewritten). A note links to its revisions by time: the row for (key, locale) with
  # the greatest valid_from at or before the note's created_at; a note older than the cell's first row uses that row.
  #
  # The locales are those the instance has (I18n.available_locales) in which the key actually has a text, without
  # fallbacks: in practice the languages the plugins ship (sv and en). Setting.available_languages is not used, since
  # it only limits what the administrator may choose for an account.
  #
  #   GkRecords::Notes.write(obj, text_key: :text_x, text_values: { 'name' => 'A' }, origin: 'system')
  #   GkRecords::Events.write(obj, kind, reason_text_key: :text_y, reason_text_values: { ... })
  #   GkRecords::SystemText.as_reason(:text_z, 'name' => 'A') { |text| owner_api!(..., reason: text) }
  # The last one carries the key through an owner plugin's own API that takes only a text: Events.write, Notes.write and
  # GkRecordsLink take the key when the reason they get is exactly that text.
  module SystemText
    # I18n's own option names cannot be values (they would be read as options, never interpolated)
    RESERVED = (defined?(::I18n::RESERVED_KEYS) ? ::I18n::RESERVED_KEYS : %i[scope default separator resolve object fallback format cascade throw raise deep_interpolation]).map(&:to_s).freeze

    # The key being given as a reason in this block (as_reason); reset by Rails between requests
    class Current < ActiveSupport::CurrentAttributes
      attribute :key, :values, :body
    end

    module_function

    def ready?
      ::GkRecordsTextRevision.table_exists?
    rescue StandardError
      false
    end

    # Whether a table has the columns text_key and text_values (migration 010)
    def columns?(klass)
      klass.column_names.include?('text_key') && klass.column_names.include?('text_values')
    rescue StandardError
      false
    end

    def default_locale = (::Setting.default_language.presence || ::I18n.default_locale).to_s

    # The values as stored: string keys, plain values (numbers and texts); a reserved I18n key is refused
    def clean_values(values)
      h = (values || {}).to_h.transform_keys(&:to_s)
      bad = h.keys & RESERVED
      raise ArgumentError, "system text values may not use I18n's reserved keys: #{bad.join(', ')}" if bad.any?

      h.transform_values { |v| v.is_a?(Numeric) || v.nil? || v == true || v == false ? v : v.to_s }
    end

    def parse_values(json)
      v = json.is_a?(Hash) ? json : JSON.parse(json.presence || '{}')
      v.is_a?(Hash) ? v : {}
    rescue JSON::ParserError
      {}
    end

    # The template for the key in one locale as the locale files say now, or nil (no fallback to another locale)
    def template(key, locale)
      t = ::I18n.backend.send(:lookup, locale.to_sym, key.to_s)
      t.is_a?(String) ? t : nil
    rescue StandardError
      nil
    end

    # Every locale of the instance with a text for the key: { 'sv' => '...', 'en' => '...' }
    def templates(key)
      ::I18n.available_locales.map(&:to_s).sort.each_with_object({}) do |l, h|
        t = template(key, l)
        h[l] = t if t
      end
    end

    def interpolate(text, values)
      return text.to_s if values.blank?

      ::I18n.interpolate(text.to_s, values.to_h.transform_keys(&:to_sym))
    rescue StandardError
      text.to_s
    end

    # The fallback body: the text in the instance's language now (then English, then the first locale that has it)
    def body(key, values = {})
      t = templates(key)
      tpl = t[default_locale] || t['en'] || t.values.first
      tpl ? interpolate(tpl, clean_values(values)) : key.to_s
    end

    def digest(text) = Digest::SHA256.hexdigest(text.to_s)

    def latest(key, locale)
      ::GkRecordsTextRevision.where(key: key.to_s, locale: locale.to_s).order(valid_from: :desc, id: :desc).first
    end

    # Each cell of the key whose text differs from its latest row gets a new row (valid_from now); the others none.
    # Returns the rows added. Called before a system text is written and, for the keys in use, at boot.
    def ensure_current!(key)
      return [] unless ready?

      now = ::Time.current
      templates(key).filter_map do |locale, text|
        sha = digest(text)
        last = latest(key, locale)
        next if last && last.sha256 == sha

        ::GkRecordsTextRevision.create!(key: key.to_s, locale: locale, body: text, sha256: sha, valid_from: now, created_at: now)
      end
    end

    # The row for one cell as it stood at a time: the latest at or before it, else the cell's first row
    def revision_at(key, locale, at)
      scope = ::GkRecordsTextRevision.where(key: key.to_s, locale: locale.to_s)
      # through the attribute, so the time is compared as the instant it is (migration 013)
      (at && scope.where(valid_from: ..at).order(valid_from: :desc, id: :desc).first) || scope.order(:valid_from, :id).first
    end

    # The text as it stood when written, in the reader's language, else the instance's, else the stored body
    def text_at(key, values, at, fallback, locale = ::I18n.locale)
      return fallback.to_s if key.blank? || !ready?

      vals = parse_values(values)
      [locale.to_s, default_locale].uniq.each do |l|
        rev = revision_at(key, l, at)
        return interpolate(rev.body, vals) if rev
      end
      fallback.to_s
    rescue StandardError
      fallback.to_s
    end

    # The text as it reads now (the cell's latest row) in the reader's language, else the instance's; nil without key
    def text_now(key, values, fallback, locale = ::I18n.locale)
      return nil if key.blank? || !ready?

      vals = parse_values(values)
      [locale.to_s, default_locale].uniq.each do |l|
        rev = latest(key, l)
        return interpolate(rev.body, vals) if rev
      end
      fallback.to_s
    rescue StandardError
      nil
    end

    # A record's text (a note's body, a link's reason, an event's reason kept in its details): render(record, locale)
    # as it stood, current(record, locale) as it reads now, changed? when the two differ (the view shows "nu: ...")
    def fallback_of(record)
      case record
      when ::GkRecordsNote then record.body
      when ::GkRecordsLink then record.reason
      when ::GkRecordsEvent then record.details_reason
      end
    end

    def keyed?(record) = record.respond_to?(:text_key) && record.text_key.present?

    def render(record, locale = ::I18n.locale)
      return fallback_of(record).to_s unless keyed?(record)

      text_at(record.text_key, record.text_values, record.created_at, fallback_of(record), locale)
    end

    def current(record, locale = ::I18n.locale)
      return nil unless keyed?(record)

      text_now(record.text_key, record.text_values, fallback_of(record), locale)
    end

    # The text now, only when it differs from the text as it stood
    def changed_text(record, locale = ::I18n.locale)
      now = current(record, locale)
      now && now != render(record, locale) ? now : nil
    end

    # For REST: the key, its values, the stored body and the text now when it differs; empty for a person's text
    def api(record, locale = ::I18n.locale)
      return {} unless keyed?(record)

      out = { text_key: record.text_key, text_values: parse_values(record.text_values), text_stored: fallback_of(record) }
      now = changed_text(record, locale)
      now ? out.merge(text_now: now) : out
    end

    # The attributes to store for a key: [fallback body, { text_key:, text_values: }]; the cells brought up to date first
    def attributes(key, values)
      vals = clean_values(values)
      ensure_current!(key)
      [body(key, vals), { text_key: key.to_s.first(200), text_values: vals.to_json }]
    end

    # A key given as a reason through an owner plugin's API that takes only a text: yields the fallback body and,
    # within the block, Events.write, Notes.write and GkRecordsLink take the key when their reason is exactly that text
    def as_reason(key, values = {})
      vals = clean_values(values)
      ensure_current!(key)
      text = body(key, vals)
      Current.set(key: key.to_s, values: vals, body: text) { yield text }
    end

    # The key and values for a reason given inside as_reason, or nil
    def claim(text)
      return nil unless Current.key && text.present? && text.to_s.strip == Current.body.to_s.strip

      [Current.key, Current.values || {}]
    end

    # Before a note or a link is made: the key and values when its text is the one given inside as_reason (a record
    # that already has a key keeps it)
    def claim_into(record, text)
      return if !columns?(record.class) || record.text_key.present?

      claimed = claim(text)
      record.assign_attributes(text_key: claimed[0].to_s.first(200), text_values: claimed[1].to_json) if claimed
    rescue StandardError => e
      Rails.logger&.warn("[gk_records] system text not kept: #{e.message}")
    end

    # The keys already used, brought up to date (a locale change between writes is recorded at the next start).
    # Guarded: not under rake, not before migration 010, once per process.
    def boot!
      return if @booted
      return if defined?(::Rake.application) && ::Rake.application.respond_to?(:top_level_tasks) && ::Rake.application.top_level_tasks.any?
      return unless ready?

      @booted = true
      keys = [::GkRecordsNote, ::GkRecordsEvent, ::GkRecordsLink].select { |k| columns?(k) }
                                                         .flat_map { |k| k.where.not(text_key: nil).distinct.pluck(:text_key) }.uniq
      added = keys.sum { |k| ensure_current!(k).size }
      Rails.logger&.info("[gk_records] system texts: #{added} revisions added for #{keys.size} keys") if added.positive?
    rescue StandardError => e
      Rails.logger&.warn("[gk_records] system texts at boot: #{e.class} #{e.message}")
    end
  end

  # Notes written by plugins: a person's text as she wrote it (body:), or the system's own text as a key
  # (text_key:, text_values:), kept with its fallback body in the instance's language
  module Notes
    module_function

    def write(target, kind: 'comment', body: nil, text_key: nil, text_values: nil, user: nil, origin: nil, parent: nil)
      t = target.is_a?(::GkRecordsNote) ? nil : Targets.for_object(target)
      type = target.is_a?(::GkRecordsNote) ? 'gk_records_note' : t&.key
      raise ArgumentError, "#{target.class.name} is not a registered records target" unless type

      attrs = { target_type: type, target_id: target.id, kind: kind.to_s, user_id: user&.id, parent_id: parent&.id }
      if text_key.present?
        text, keyed = SystemText.attributes(text_key, text_values)
        attrs[:body] = text
        attrs.merge!(keyed) if SystemText.columns?(::GkRecordsNote)
        attrs[:origin] = origin || 'system'
      else
        attrs[:body] = body.to_s
        attrs[:origin] = origin || 'human' # inside SystemText.as_reason the model takes the key (claim_into)
      end
      ::GkRecordsNote.create!(attrs)
    end
  end
end
