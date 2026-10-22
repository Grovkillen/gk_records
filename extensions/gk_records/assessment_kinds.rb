# frozen_string_literal: true

require 'json'

module GkRecords
  # Assessment kinds as data. Before, a kind came only from a plugin's code (Kinds.register_assessment), so dual use or
  # capacity on a company could not be said without new code (the principles: "Verksamheten är data, inte kod").
  # A kind that is data has a key, its names per language and optionally a scale: the outcomes it is valued on, each
  # with its names. The kinds are kept in records' own settings (assessment_kinds, a JSON list), an existing generic
  # place: no table, no migration, and every change is an event in the settings' history with its person and reason
  # (SettingsHistory). The settings page carries the list unchanged when it is saved. Kinds.find and Kinds.of see these
  # beside the registered ones, so an assessment of such a kind is made, validated and shown as any other
  # (Assessments.record). A kind is never removed here (assessments of it are kept whole, P1); its names and scale may
  # change, and an assessment keeps the outcome text it was made with.
  #   GkRecords::AssessmentKinds.save!('dual_use', names: { 'sv' => 'Dubbla användningsområden', 'en' => 'Dual use' },
  #                                     scale: [{ 'key' => 'possible', 'names' => { 'sv' => 'Möjligt', 'en' => 'Possible' } }],
  #                                     reason: 'Förstudien bedömer företagen')
  module AssessmentKinds
    SETTING = 'assessment_kinds'
    PLUGIN = 'data'
    # The kind column holds 40 characters
    KEY = /\A[a-z][a-z0-9_]{0,39}\z/

    module_function

    def raw
      s = ::Setting.plugin_gk_records
      s.respond_to?(:to_h) ? s.to_h[SETTING].to_s : ''
    rescue StandardError
      ''
    end

    # The stored rows: [{ 'key', 'names' => { lang => text }, 'scale' => [{ 'key', 'names' }] }]
    def rows(text = raw)
      list = JSON.parse(text.presence || '[]')
      list.is_a?(Array) ? list.select { |r| r.is_a?(Hash) && r['key'].to_s.match?(KEY) } : []
    rescue JSON::ParserError
      []
    end

    # The kinds (Kind, scope assessment, plugin data), read again only when the setting changed
    def all
      text = raw
      cache = @cache
      return cache.last if cache && cache.first == text

      kinds = rows(text).map { |r| kind(r) }.freeze
      @cache = [text, kinds]
      kinds
    end

    def find(key) = all.detect { |k| k.key == key.to_s }

    def kind(row)
      Kind.new(scope: 'assessment', key: row['key'].to_s, plugin: PLUGIN, label_key: nil, names: clean_names(row['names']).freeze,
               scale: clean_scale(row['scale']).freeze, person_fields: [].freeze, private_fields: [].freeze, citation: false)
    end

    # { lang => text }, trimmed, empty ones left out
    def clean_names(value)
      (value.is_a?(Hash) ? value : {}).to_h { |l, t| [l.to_s, t.to_s.strip] }.reject { |l, t| l.empty? || t.empty? }
    end

    # [{ 'key', 'names' }] in the order given, a key once
    def clean_scale(value)
      Array(value).filter_map do |v|
        h = v.is_a?(Hash) ? v.to_h.transform_keys(&:to_s) : {}
        k = h['key'].to_s
        k.match?(KEY) ? { 'key' => k, 'names' => clean_names(h['names']) } : nil
      end.uniq { |v| v['key'] }
    end

    # A key a plugin registered in code is the plugin's (data never shadows it)
    def coded?(key) = Kinds.all.key?("assessment:#{key}")

    # Makes the kind or changes its names and scale, as User.current with the reason in the settings' history. true when
    # something changed, false when it was already so. Raises ArgumentError on a bad key, a plugin's key or no name.
    def save!(key, names:, scale: nil, reason: nil)
      key = key.to_s
      raise ArgumentError, "assessment kind #{key}: a key is a to z, 0 to 9 and _, at most 40" unless key.match?(KEY)
      raise ArgumentError, "assessment kind #{key} is registered by a plugin" if coded?(key)

      n = clean_names(names)
      raise ArgumentError, "assessment kind #{key}: a name is needed" if n.empty?

      row = { 'key' => key, 'names' => n, 'scale' => clean_scale(scale) }
      list = rows
      i = list.index { |r| r['key'] == key }
      return false if i && list[i] == row

      i ? list[i] = row : list << row
      now = ::Setting.plugin_gk_records
      now = now.respond_to?(:to_h) ? now.to_h.dup : {}
      SettingsHistory.with_reason(reason) { ::Setting.plugin_gk_records = now.merge(SETTING => list.to_json) }
      true
    end
  end
end
