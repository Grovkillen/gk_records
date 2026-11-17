# frozen_string_literal: true

module GkRecords
  # The words of the verification status and the row's name, per place and language, under fields' Översättningar:
  # one tab, Verifieringsstatus (GK Records), with a row for the row's name and one per level that is on, for the issue
  # default, every tracker with verification, the assessments and the places other plugins register (people's persons,
  # organizations and groups). The words stay in records' settings (Verification's verification_places); fields reads
  # them from here and saves back through Verification.save_words!, which keeps the change in the settings' history.
  # The column as written is the word in force in the core language; every language the page edits can hold a word of
  # the installation's own, the core language too, and an empty field gives the place's default back.
  module VerificationTexts
    SOURCE = 'gk_records_verification'

    module_function

    def t = ::GkFields::Translations
    def v = Verification

    def register!
      return unless defined?(::GkFields::Translations) && t.respond_to?(:register_source)

      t.register_source(SOURCE, label: -> { ::I18n.t(:label_gk_records_verification_words) }, entries: -> { entries })
    end

    # The places in a fixed order: the issue default, the trackers with verification, the assessments, the others
    def place_keys
      trackers = v.tracker_ids.map { |id| Verification::Ladder.tracker_place(id) }
      rest = v.places.keys - %w[issue gk_records_assessment]
      (%w[issue] + trackers + (v.places.key?('gk_records_assessment') ? %w[gk_records_assessment] : []) + rest.sort).uniq
    end

    # The place as the page names it: Ärenden, förval; Ärendetyp: <name>; the sort of thing for the others
    def thing(place)
      return ::I18n.t(:label_gk_records_verification_place_issue) if place == 'issue'

      if (tid = Verification::Ladder.tracker_of(place))
        name = ::Tracker.where(id: tid).pick(:name) || tid.to_s
        return ::I18n.t(:label_gk_records_verification_place_tracker, name: name)
      end
      return ::I18n.t(:label_gk_records_assessment) if place == 'gk_records_assessment'

      Targets.thing_label(place)
    end

    def entries
      core = t.core_language
      langs = t.editable_languages
      place_keys.flat_map do |place|
        name = thing(place)
        own = v.stored(place)
        rows = [entry(place, 'title', name, ::I18n.t(:label_gk_records_verification_row_name), v.title(place, lang: core),
                      (own['title'] || {}).slice(*langs), :title)]
        v.levels(place).each do |step|
          what = "#{v.i18n(step == Verification::NONE ? :label_gk_records_verification_none : "label_gk_records_verification_#{step}")} (#{step})"
          rows << entry(place, step, name, what, v.pill_label(step, place: place, lang: core), ((own['words'] || {})[step] || {}).slice(*langs), step)
        end
        rows
      end
    end

    def entry(place, key, thing, what, core_text, translations, saved)
      t::Entry.new(key: "#{SOURCE}:#{place}:#{key}", thing: thing, what: what, core: core_text, translations: translations, history: nil,
                   saver: lambda { |texts, _user, _origin|
                     v.save_words!(place, saved, texts.to_h.slice(*t.editable_languages), reason: ::I18n.t(:text_gk_records_verification_translated))
                   })
    end
  end
end
