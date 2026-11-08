# frozen_string_literal: true

module GkRecords
  # The register's list and action values, the warnings of a setting and the event on a setting's row for something done
  # to what the setting keeps (GkRecords::AppearanceSettings, reopened here to keep that file small).
  #   list:   one entry per line; max is the most entries, pattern a Regexp each entry must match; the value is an Array
  #   action: a button under the setting that posts to url (a route helper name) with confirm (a locale key) and the
  #           form's reason; it keeps no value and a save never takes it
  module AppearanceSettings
    LIST_ENTRY_MAX = 255

    # pattern: each list entry must match it; placeholder: a String or a lambda giving the text field's placeholder;
    # url: the route helper an action posts to; confirm_key: the locale key of the action's confirmation
    class Value
      def placeholder_text
        (placeholder.respond_to?(:call) ? placeholder.call : placeholder).to_s
      rescue StandardError
        ''
      end

      def confirm = confirm_key && ::I18n.exists?(confirm_key) ? ::I18n.t(confirm_key) : ''
    end

    # person_default: where an optional setting stands for a person who has not chosen ('on' or 'off'). warning_key and
    # warning_sharp_key: the row's warning and the sharper one, shown when sharp_when holds ({ 'value' => name,
    # 'includes' => entry }). reason_when_sharp: a save that leaves the row on and sharp needs a reason.
    class Row
      def person_only? = modes == PERSON_MODES

      def warning(sharp = false)
        k = [sharp ? warning_sharp_key : nil, warning_key].compact.find { |x| ::I18n.exists?(x) }
        k ? ::I18n.t(k) : ''
      end

      def sharp?(given)
        return false unless sharp_when

        h = (given || {}).to_h.transform_keys(&:to_s)
        Array(h[sharp_when['value']]).map(&:to_s).include?(sharp_when['includes'].to_s)
      end
    end

    module_function

    # The keywords register adds for warnings and the person's default, checked against the row's values; returns the
    # sharp_when hash with string keys, or nil
    def check_extras(key, values, person_default, sharp_when)
      raise ArgumentError, "appearance setting #{key}: person_default #{person_default}" unless %w[on off].include?(person_default.to_s)
      return nil if sharp_when.nil?

      h = sharp_when.is_a?(Hash) ? sharp_when.transform_keys(&:to_s) : nil
      unless h && h.keys.sort == %w[includes value] && values.key?(h['value'].to_s)
        raise ArgumentError, "appearance setting #{key}: sharp_when needs value (one of its values) and includes"
      end

      { 'value' => h['value'].to_s, 'includes' => h['includes'].to_s }.freeze
    end

    # A list as it is kept: one entry per line (or an Array), each stripped, empty lines dropped, the first of entries
    # that differ only in case kept as written; nil when there are more than max entries, an entry is too long, or an
    # entry does not match the pattern
    def coerce_list(v, raw)
      items = case raw
              when String then raw.split(/\r?\n/)
              when Array then raw.map(&:to_s)
              end
      return nil unless items

      out = items.map(&:strip).reject(&:empty?).uniq(&:downcase)
      return nil if v.max && out.size > v.max
      return nil if out.any? { |e| e.length > LIST_ENTRY_MAX }
      return nil if v.pattern && out.any? { |e| !v.pattern.match?(e) }

      out
    end

    # A save that leaves a reason_when_sharp row on and sharp, and changes its level or values, needs a reason; raises
    # ReasonNeeded so that the whole save is refused
    def check_sharp_reason!(row, new_mode, new_values, reason)
      return unless row.reason_when_sharp && reason.to_s.strip.empty?

      before_mode = mode(row.key)
      before = row.values.keys.to_h { |n| [n, value(row.key, n)] }
      final_mode = new_mode || before_mode
      final = before.merge(new_values)
      return if final_mode == 'off' || !row.sharp?(final)
      return if final_mode == before_mode && final == before

      raise ReasonNeeded.new(row.key, 'reason')
    end

    # Whether the setting is in its sharp state: values nil reads the instance's current values
    def sharp?(key, values = nil)
      row = find(key)
      return false unless row&.sharp_when

      row.sharp?(values || row.values.keys.to_h { |n| [n, value(row.key, n)] })
    end

    # An event on the instance's row of a setting, for something done to what the setting keeps (the caller registers
    # the kind with target appearance_setting). Like every event of the register, a failure is logged, never raised.
    def record_on!(key, kind, details:, reason: nil, reason_key: nil, user: User.current)
      row = find(key) or raise ArgumentError, "appearance setting #{key} is not declared"

      rec = begin
        ::GkRecordsAppearanceSetting.find_or_create_by!(key: row.key, user_id: ::GkRecordsAppearanceSetting::INSTANCE)
      rescue StandardError => e
        Rails.logger.warn("[gk_records] appearance setting row not ready for #{row.key}: #{e.message}")
        return nil
      end
      record(rec, kind.to_s, { 'appearance_setting' => row.key }.merge((details || {}).to_h.transform_keys(&:to_s)),
             reason, reason_key, user)
    end
  end
end
