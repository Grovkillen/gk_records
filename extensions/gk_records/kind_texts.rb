# frozen_string_literal: true

module GkRecords
  # The names of the assessment kinds that are data (AssessmentKinds), and of the outcomes on their scales, under
  # fields' Översättningar, the one place for the other languages of every name an administrator sets. They stay where
  # they are kept (records' settings); fields reads them from there and saves back through AssessmentKinds.save!, which
  # keeps the change in the settings' history. The name in the core language is the one written and is not changed here.
  module KindTexts
    SOURCE = 'gk_records_assessment_kinds'

    module_function

    def t = ::GkFields::Translations

    def register!
      return unless defined?(::GkFields::Translations) && t.respond_to?(:register_source)

      t.register_source(SOURCE, label: -> { ::I18n.t(:label_gk_records_assessment_kinds_data) }, entries: -> { entries })
    end

    def entries
      core = t.core_language
      AssessmentKinds.rows.flat_map do |row|
        kind = row['key']
        names = row['names'].is_a?(Hash) ? row['names'] : {}
        base = names[core].presence or next []
        out = [entry("#{kind}:name", base, ::I18n.t(:field_name), names, core) { |texts, user| save(kind, nil, core, texts, user) }]
        Array(row['scale']).each do |o|
          on = o['names'].is_a?(Hash) ? o['names'] : {}
          ob = on[core].presence or next
          out << entry("#{kind}:#{o['key']}", ob, "#{base}: #{::I18n.t(:label_gk_records_scale_outcome)}", on, core) { |texts, user| save(kind, o['key'], core, texts, user) }
        end
        out
      end
    end

    def entry(key, core_text, what, names, core, &save)
      t::Entry.new(key: "#{SOURCE}:#{key}", thing: core_text, what: what, core: core_text, translations: names.except(core), history: nil,
                   saver: ->(texts, user, _origin) { save.call(texts, user) })
    end

    # The other languages of a kind's name (outcome nil) or an outcome's name; true when something changed
    def save(kind, outcome, core, texts, _user)
      row = AssessmentKinds.rows.detect { |r| r['key'] == kind } or return false
      target = outcome ? Array(row['scale']).detect { |o| o['key'] == outcome } : row
      return false unless target

      names = target['names'].is_a?(Hash) ? target['names'] : {}
      before = names.except(core)
      after = before.merge(texts.to_h.transform_keys(&:to_s).transform_values { |v| v.to_s.strip }).reject { |_l, v| v.blank? }
      return false if after == before

      target['names'] = { core => names[core] }.merge(after)
      AssessmentKinds.save!(kind, names: row['names'], scale: row['scale'], reason: ::I18n.t(:text_gk_records_kind_translated))
      true
    end
  end
end
