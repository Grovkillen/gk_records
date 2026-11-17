# frozen_string_literal: true

require_relative 'verification_ladder'

module GkRecords
  #   GkRecords::Verification.get(obj)                    # => 'unverified' or nil
  #   GkRecords::Verification.set!(obj, 'hypothesis', user: User.current, reason: 'Inte prövat än')
  # A thing without a row has no status said (nil), which is not the same as unverified.
  #
  # The ladder is one and the same everywhere (verification_ladder.rb): none, hypothesis, unverified, partly_verified,
  # verified, in that order, with fixed keys; none, unverified and verified are on every place, hypothesis and
  # partly_verified are chosen per place. A place is where a thing's row stands: "issue:<tracker_id>" for an issue (its
  # tracker, falling back to the issue default "issue"), else the thing's records target key (gk_records_assessment,
  # person, organization, group). The plugin that owns the place registers it with register_content: the row's name,
  # the words, the optional levels on by default and whether verified is set only through an approved review.
  # The administrator ticks the optional levels where the place is set up (the tracker's page, records' and people's
  # settings; the partial gk_records/verification_levels) and changes the words and the row's name per language under
  # Translations in GK Fields (VerificationTexts). Records keeps every place's choices in its settings
  # (verification_places).
  # 1. Verified is set only through an approved review in signoff where the place says so (review: :always, issues and
  #    assessments): set!(obj, 'verified') is refused (Refused) there unless the reviewer (register_reviewer) says an
  #    approved review exists for the content as it is now. Where the place does not lock it, whoever may change the
  #    thing sets it by hand, as the other levels (change, with the reason place records.verification).
  # 2. Changed after the review: the stored status stays; changed_since_review? asks the reviewer when it is shown.
  # 3. The row on issues of the trackers the administrator chooses (setting verification_tracker_ids), the column and
  #    filter in the issue list, records' assessments and the places other plugins register.
  # 4. Nothing is set when a thing is made. A row whose status was cleared keeps the row with the status none (rows are
  #    never deleted); get gives nil.
  module Verification
    NONE = 'none'
    EVENT = 'verification_changed'
    FEATURE = 'records.verification'
    REASON = 'records.verification'
    # Sorting in the issue list: the surest first, none last
    ORDER = { 'verified' => 1, 'partly_verified' => 2, 'unverified' => 3, 'hypothesis' => 4 }.freeze
    # Each step's role as a GK GUI Stuff pill role (none quiet, hypothesis notice, unverified warning, partly verified
    # info, verified saved); the one place that holds them
    ROLES = { NONE => :muted, 'hypothesis' => :notice, 'unverified' => :warning, 'partly_verified' => :info, 'verified' => :saved }.freeze
    # change's code when the step would move while a review is open: the page asks, and sends withdraw to go on
    OPEN_REVIEW = 'open_review'
    # Records' setting that holds every place's choices: { place => { 'optional' => [...], 'title' => { lang => text },
    # 'words' => { step => { lang => text } } } }
    PLACES_SETTING = 'verification_places'
    # Seconds a count of the levels in use on a place is kept
    USED_TTL = 30

    # set!(obj, 'verified') without an approved review for the content as it is now, where the place locks it
    class Refused < StandardError; end

    # A registered place: title (a locale key, { lang => text } or a callable with the language), words ({ step =>
    # the same }), optional_on (the optional levels on by default), review (:always, :never or ->(obj) { true }),
    # manage (->(user) { true } for who may tick its levels besides an administrator; no page asks it yet, see
    # may_manage_levels?)
    Place = Struct.new(:key, :title, :words, :optional_on, :review, :manage, keyword_init: true)

    module_function

    # ------------------------------------------------------------------ the words
    def lang_now
      l = defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:lang) ? ::GkFields::Translations.lang : ::I18n.locale
      l.to_s.presence || ::I18n.locale.to_s
    rescue StandardError
      ::I18n.locale.to_s
    end

    # A locale text in a language Redmine has, else in the current one
    def i18n(key, lang = nil, default = '')
      loc = lang.to_s.presence&.to_sym
      loc = ::I18n.locale unless loc && ::I18n.available_locales.include?(loc)
      ::I18n.t(key, locale: loc, default: default).to_s
    rescue StandardError
      default.to_s
    end

    # The word a place registered for a step (or :title), in a language; nil when it registered none
    def registered_word(place_def, step, lang)
      v = step == :title ? place_def&.title : (place_def&.words || {})[step.to_s]
      case v
      when nil then nil
      when Hash then Ladder.word(v.transform_keys(&:to_s), lang)
      when Proc then v.call(lang).to_s.strip.presence
      else i18n(v, lang).strip.presence
      end
    rescue StandardError
      nil
    end

    # The installation's own word for a step (or :title) on a place, in a language
    def own_word(place, step, lang)
      h = stored(place)
      step == :title ? Ladder.word(h['title'], lang) : Ladder.word((h['words'] || {})[step.to_s], lang)
    end

    # The word in this order: the place's own word for the language, the place's locale key, for an issue's tracker
    # the issue default (its own word, then its key); nil leaves it to the ladder's own key
    def word_for(place, step, lang = nil)
      return nil if place.blank?

      lang ||= lang_now
      chain = [place.to_s]
      chain << 'issue' if Ladder.tracker_of(place)
      chain.each do |p|
        w = own_word(p, step, lang) || registered_word(places[p], step, lang)
        return w if w
      end
      nil
    end

    # A step's word on a place; '' for none (the pill says Ingen status, pill_label)
    def label(status, place: nil, lang: nil)
      s = status.to_s
      return '' if s.empty? || s == NONE

      word_for(place, s, lang) || i18n("label_gk_records_verification_#{s}", lang, s)
    end

    # The pill's word: the step, or the place's word for none (Ingen status)
    def pill_label(status, place: nil, lang: nil)
      s = status.to_s
      return label(s, place: place, lang: lang) unless s.empty? || s == NONE

      word_for(place, NONE, lang) || i18n(:label_gk_records_verification_none, lang)
    end

    def role(status) = ROLES[status.to_s.presence || NONE] || :muted

    # The row's name on a place (Verifieringsstatus by default)
    def title(place = nil, lang: nil) = word_for(place, :title, lang) || i18n(:label_gk_records_verification_status, lang)

    def ready?
      ::GkRecordsVerification.table_exists?
    rescue StandardError
      false
    end

    # On when a tracker has it or a plugin asked for it; off for a new installation (GkRecords::Features)
    def feature? = Features.on?('verification')

    def row(obj)
      t = Targets.for_object(obj)
      t && obj&.id ? ::GkRecordsVerification.find_by(target_type: t.key, target_id: obj.id) : nil
    end

    def get(obj)
      s = row(obj)&.status
      s == NONE ? nil : s
    end

    # ------------------------------------------------------------------ the places
    def places = (@places ||= {})

    # The content a review is bound to, and the place. The old form register_content(key, fn) works as before (all five
    # levels, the ladder's words, verified only through the review). With the keywords the owner gives the place's row
    # name, words, the optional levels on by default and the review rule; a keyword left out keeps what was registered.
    #   GkRecords::Verification.register_content('person', fn, title: :label_x, words: { 'unverified' => :label_y },
    #                                            optional_on: %w[partly_verified], review: ->(obj) { false })
    def register_content(key, fn = nil, title: nil, words: nil, optional_on: nil, review: nil, manage: nil)
      k = key.to_s
      contents[k] = fn if fn
      p = (places[k] ||= Place.new(key: k, words: {}))
      p.title = title unless title.nil?
      p.words = words.to_h.transform_keys(&:to_s).slice(*LADDER) unless words.nil?
      p.optional_on = OPTIONAL & Array(optional_on).map(&:to_s) unless optional_on.nil?
      p.review = review unless review.nil?
      p.manage = manage unless manage.nil?
      p
    end

    # Records' own places: the issue default (each tracker falls back to it) and the assessments
    def register_places!
      register_content('issue', ->(i) { "subject=#{i.subject}\u0000description=#{i.description}" },
                       title: :label_gk_records_verification_status, optional_on: OPTIONAL, review: :always)
      register_content('gk_records_assessment', ->(a) { [a.kind, a.title, a.outcome, a.data, a.basis].map(&:to_s).join("\u0000") },
                       title: :label_gk_records_verification_status, optional_on: OPTIONAL, review: :always)
    end

    # The place of a thing: "issue:<tracker_id>" for an issue, else its records target key
    def place(obj)
      return nil unless obj
      return Ladder.tracker_place(obj.tracker_id) if obj.is_a?(::Issue)

      Targets.for_object(obj)&.key
    end

    # The issues' places found in this request ({ issue id => place }), so a list of events asks once per issue at most
    class Current < ActiveSupport::CurrentAttributes
      attribute :issue_places, :posted_settings
    end

    # The settings a plugin's settings form posts, { plugin id => settings }, while that form's levels are checked
    # before core saves them: a place whose review rule reads a setting of the same form (people's review per place)
    # asks posted_settings first, so the levels are judged by what the page will save, not by what it had
    def with_posted_settings(plugin_id, settings)
      before = Current.posted_settings
      Current.posted_settings = before.to_h.merge(plugin_id.to_s => settings)
      yield
    ensure
      Current.posted_settings = before
    end

    def posted_settings(plugin_id) = Current.posted_settings.to_h[plugin_id.to_s]

    def issue_places = (Current.issue_places ||= {})

    # The place of a stored target (an event's, a row's): an issue's by its tracker now
    def place_of(target_type, target_id)
      return target_type.to_s unless target_type.to_s == 'issue'

      id = target_id.to_i
      known = issue_places
      return known[id] if known.key?(id)

      tid = ::Issue.where(id: id).pick(:tracker_id)
      known[id] = tid ? Ladder.tracker_place(tid) : 'issue'
    rescue StandardError
      'issue'
    end

    # The places of the issues a list of events is about, in one query (the events page, its CSV and the search)
    def preload_places(events)
      ids = Array(events).select { |e| e.kind == EVENT && e.target_type.to_s == 'issue' }.map { |e| e.target_id.to_i }.uniq
      known = issue_places
      ids -= known.keys
      return if ids.empty?

      found = ::Issue.where(id: ids).pluck(:id, :tracker_id).to_h
      ids.each { |i| known[i] = found[i] ? Ladder.tracker_place(found[i]) : 'issue' }
    rescue StandardError => e
      Rails.logger.warn("[gk_records] the issues' verification places not preloaded: #{e.class} #{e.message}")
    end

    # A verification event's change of the status as one line, in the words of its place: "Uppgifternas status:
    # Osäkra > Delvis bekräftade" (the keys stay in the API)
    def change_line(event, before, after, sep = '>')
      pl = place_of(event.target_type, event.target_id)
      Ladder.change_line(title(pl), pill_label(before, place: pl), pill_label(after, place: pl), sep)
    end

    # The registration that holds for a place (a tracker's is the issue default's)
    def place_def(place) = places[place.to_s] || places[Ladder.base(place)]

    # A place that has levels to tick: a registered one, or a tracker that exists and has the row
    def known_place?(place)
      return true if places.key?(place.to_s) && !Ladder.tracker_of(place)

      (tid = Ladder.tracker_of(place)) ? tracker?(tid) && ::Tracker.where(id: tid).exists? : false
    rescue StandardError
      false
    end

    # Is verified set only through an approved review for this thing (its place's rule; issues and assessments always)
    def review_locked?(obj) = Ladder.locked?(place_def(place(obj))&.review, obj)

    # The same for a place as a whole (a rule per thing is asked without one)
    def place_locked?(place) = Ladder.locked?(place_def(place)&.review, nil)

    # Who may tick a place's levels: an administrator, or whom the place's owner names (register_content manage:).
    # The levels are now saved only with the administrator's forms where the place is set up (the tracker's page and
    # the settings pages), so no page asks this yet and manage: has no effect; both stay for a page that lets the
    # place's owner hand the levels to others
    def may_manage_levels?(place, user = ::User.current)
      return false unless user&.logged? && known_place?(place)
      return true if user.admin?

      fn = place_def(place)&.manage
      fn ? !!fn.call(user) : false
    rescue StandardError
      false
    end

    # ------------------------------------------------------------------ the stored choices
    def stored_places
      s = ::Setting.plugin_gk_records
      raw = s.respond_to?(:to_h) ? s.to_h[PLACES_SETTING] : nil
      cache = @stored_cache
      return cache.last if cache && cache.first == raw

      clean = Ladder.clean_places(raw)
      @stored_cache = [raw.deep_dup, clean]
      clean
    rescue StandardError
      {}
    end

    def stored(place) = stored_places[place.to_s] || {}

    # Writes one place's choices into records' settings (the settings' history logs it, with the reason)
    def save_place!(place, reason: nil)
      now = ::Setting.plugin_gk_records
      now = now.respond_to?(:to_h) ? now.to_h.dup : {}
      all = stored_places.deep_dup
      h = yield(all[place.to_s] || {})
      h = Ladder.clean_place(h)
      h.empty? ? all.delete(place.to_s) : all[place.to_s] = h
      SettingsHistory.with_reason(reason) { ::Setting.plugin_gk_records = now.merge(PLACES_SETTING => all) }
      @stored_cache = nil
      true
    end

    # The optional levels that are on at a place: its own choice, for a tracker the issue default's, else the default
    def chosen_optional(place)
      base = Ladder.tracker_of(place) ? stored('issue')['optional'] : nil
      Ladder.chosen_optional(stored(place)['optional'], base, place_def(place)&.optional_on)
    end

    # The levels at a place, in the ladder's order: the forced ones, the optional ones that are on, and an optional one
    # that is off but still has records there (it stays until they are moved)
    def levels(place)
      chosen = chosen_optional(place)
      off = OPTIONAL - chosen
      Ladder.levels(chosen, off.empty? ? [] : used(place, off))
    end

    # The levels one thing's box offers: the forced ones, the optional ones that are on, and the thing's own status
    # when it is an optional level that is off. A level that is off but kept by other records is not offered (it is
    # off; nothing new is set to it) and so tells no reader that records she may not see still have it.
    def levels_for(obj, status = :ask)
      status = get(obj) if status == :ask
      Ladder.levels(chosen_optional(place(obj)), [status].compact)
    end

    # The records of a place: a tracker's issues; for the issue default the issues of the trackers that follow it;
    # else the rows of the place's target whose thing is still there (a row of a thing that is gone is never counted,
    # so it cannot keep a level that is off)
    def scope_for(place)
      v = ::GkRecordsVerification
      if (tid = Ladder.tracker_of(place))
        v.where(target_type: 'issue', target_id: ::Issue.where(tracker_id: tid).select(:id))
      elsif place.to_s == 'issue'
        follow = tracker_ids.reject { |t| stored(Ladder.tracker_place(t)).key?('optional') }
        follow.empty? ? v.none : v.where(target_type: 'issue', target_id: ::Issue.where(tracker_id: follow).select(:id))
      else
        rows = v.where(target_type: place.to_s)
        model = begin
          Targets.find(place)&.model_class
        rescue StandardError
          nil
        end
        model ? rows.where(target_id: model.select(model.primary_key)) : rows
      end
    end

    def count_at(place, level)
      ready? ? scope_for(place).where(status: level.to_s).count : 0
    rescue StandardError
      0
    end

    # Which of statuses have records on the place, counted at run time and kept a short while
    def used(place, statuses)
      key = [place.to_s, statuses.sort]
      hit = (@used ||= {})[key]
      return hit.last if hit && ::Time.now - hit.first < USED_TTL

      list = ready? ? scope_for(place).where(status: statuses).distinct.pluck(:status) : []
      @used = @used.merge(key => [::Time.now, list])
      list
    rescue StandardError
      []
    end

    def forget_used! = (@used = {})

    # ------------------------------------------------------------------ ticking the levels, and moving their records
    # The levels are plain check boxes in the form where the place is set up (the tracker's form, records' and
    # people's settings), saved with that form's Save: the partial posts LEVELS_PARAM[<place>][<step>] and, from the
    # move box, [move][<step>] and [reason][<step>]. The page checks every place first (check_levels) and saves
    # nothing when something is missing; after the form is saved it carries out the plans (apply_levels!).
    LEVELS_PARAM = 'gk_records_vlevels'
    # The place a tracker that is not saved yet posts its levels under: it falls back to the issue default and has no
    # issues; once the tracker is created its plan is carried out for issue:<id>
    NEW_TRACKER_PLACE = 'issue:0'

    # [plans, errors] for the posted levels (params[LEVELS_PARAM]): plans { place => Ladder.level_plan } with the
    # moves' reasons checked by the reason place records.verification, errors [text] that say place, level and what
    # is missing. only: the places the caller vouches for (the tracker's own, also while it has no verification
    # status yet); without it a place must be one that has levels (known_place?).
    def check_levels(raw, only: nil)
      plans = {}
      errors = []
      Ladder.hashify(raw).each do |place, value|
        pl = place.to_s
        next if only && !Array(only).map(&:to_s).include?(pl)

        unless only || known_place?(pl)
          errors << ::I18n.t(:error_gk_records_vlevels_place)
          next
        end
        posted = Ladder.posted_levels(value)
        counts = posted['off'].to_h { |s| [s, count_at(pl, s)] }
        plan = Ladder.level_plan(posted, chosen: chosen_optional(pl), levels: levels(pl), counts: counts, locked: place_locked?(pl))
        plan['errors'].each do |step, why|
          next if why == :reason_missing # the reason's place decides below

          errors << level_error(pl, step, :error_gk_records_vlevels_target)
        end
        plan['moves'].each do |step, m|
          next unless move_target_ok?(plan, step)

          check = Reasons.check(REASON, m['reason'])
          if check.ok
            m['reason'] = check.text.presence
          else
            errors << level_error(pl, step, check.error)
          end
        end
        plans[pl] = plan
      end
      [plans, errors]
    end

    def move_target_ok?(plan, step) = plan['errors'].none? { |s, why| s == step && why == :target }

    # "Hypotes (Verifieringsstatus): Välj en nivå att flytta posterna till."
    def level_error(place, step, error)
      text = error.is_a?(Symbol) ? ::I18n.t(error) : error.to_s
      ::I18n.t(:error_gk_records_vlevels_at, step: label(step, place: place), title: title(place), error: text)
    end

    # The flash when the posted levels stop a save: nothing was saved, and each thing that is missing
    def levels_refused(errors) = ::I18n.t(:error_gk_records_vlevels_not_saved, errors: Array(errors).uniq.join(' '))

    # Carries out the plans of check_levels after the form around the levels was saved: per place the records of a
    # level switched off are moved first, then the optional levels are written. rename: { posted place => place }
    # (a tracker created by this save). [true, nil] or [false, message]; a place that fails keeps what it had.
    # saved: the form around the levels was already saved, and the message says so (the page's other fields changed,
    # the levels did not, and the move can be made again)
    def apply_levels!(plans, user: ::User.current, rename: {}, saved: false)
      failed = []
      plans.to_h.each do |place, plan|
        next unless Ladder.plan_changes?(plan)

        ok, error = apply_level_plan!(rename.to_h[place] || place, plan, user)
        failed << error unless ok
      end
      return [true, nil] if failed.empty?

      text = failed.uniq.join(' ')
      [false, saved ? ::I18n.t(:error_gk_records_vlevels_saved_not_moved, errors: text) : text]
    end

    # One place's plan in one transaction: every record of a level switched off is set to its target with set!
    # (origin move, an event with the reason on each, for issues a history entry that sends no mail), and only then the
    # optional levels are written (the settings' history logs it with the reasons)
    def apply_level_plan!(place, plan, user)
      pl = place.to_s
      moves = plan['moves'].to_h
      ::GkRecordsVerification.transaction do
        moves.each do |step, m|
          # only the rows whose thing is there (scope_for), so the level really goes once they are moved
          scope_for(pl).where(status: step).order(:id).each do |r|
            obj = r.target_type == 'issue' ? ::Issue.find_by(id: r.target_id) : Targets.resolve("#{r.target_type}:#{r.target_id}")&.last
            next unless obj

            set!(obj, m['to'].to_s, user: user, reason: m['reason'], origin: 'move', notify: false)
          end
        end
        if plan['write']
          why = moves.values.filter_map { |m| m['reason'] }.uniq.join(' ').presence
          save_place!(pl, reason: why) { |h| h.merge('optional' => plan['optional']) }
        end
      end
      forget_used!
      [true, nil]
    rescue Refused => e
      # Refused carries its own localized text
      forget_used!
      [false, ::I18n.t(:error_gk_records_vlevels_move_failed, why: e.message)]
    rescue StandardError => e
      # anything else (an invalid record, a statement or lock that fails, a target that cannot be resolved): the
      # transaction is rolled back, the developer's text goes to the log and the reader gets a fixed one. The page
      # around the levels may already be saved, so the error never escapes as a server error
      Rails.logger.warn("[gk_records] verification levels at #{pl} not saved: #{e.class} #{e.message}")
      forget_used!
      [false, ::I18n.t(:error_gk_records_vlevels_move_failed, why: ::I18n.t(:text_gk_records_vlevels_move_broken))]
    end

    # One level switched on or off at once, for scenarios and tests (the pages save the levels with their form):
    # the same check and the same move as a form's Save. [ok, message]
    def set_level!(place, level, on, move_to: nil, reason: nil, user: ::User.current)
      pl = place.to_s
      lv = level.to_s
      return [false, ::I18n.t(:error_gk_records_vlevels_place)] unless known_place?(pl)
      return [false, ::I18n.t(:error_gk_records_vlevels_level)] unless OPTIONAL.include?(lv)

      raw = { pl => { lv => on ? '1' : '0', 'move' => { lv => move_to.to_s }, 'reason' => { lv => reason.to_s } } }
      plans, errors = check_levels(raw)
      return [false, errors.first] if errors.any?

      apply_levels!(plans, user: user)
    end

    # Records' own settings form posts the whole settings hash, which core stores as it is: the places' choices are
    # put in from what is stored now, so the form never writes back an old copy (the words may have been changed
    # under Translations since the page was drawn)
    def carry_places!(settings)
      return unless settings.respond_to?(:[]=)

      settings[PLACES_SETTING] = stored_places.deep_dup
    end

    # The installation's words for a place: what (:title or a step) => { lang => text }; true when something changed
    def save_words!(place, what, texts, reason: nil)
      key = what == :title ? 'title' : what.to_s
      return false unless key == 'title' || LADDER.include?(key)

      before = key == 'title' ? (stored(place)['title'] || {}) : ((stored(place)['words'] || {})[key] || {})
      after = before.merge(texts.to_h.to_h { |l, t| [l.to_s, t.to_s.strip] }).reject { |_l, t| t.empty? }
      return false if after == before

      save_place!(place, reason: reason) do |h|
        if key == 'title'
          h.merge('title' => after)
        else
          h.merge('words' => (h['words'] || {}).merge(key => after))
        end
      end
      true
    end

    # ------------------------------------------------------------------ the review
    # One plugin reviews (signoff): approved: ->(obj) { the approving signature for the content now, or nil };
    # changed: ->(obj) { true when the content changed after the last approval }; partial: drawn in the row with
    # locals obj and back_url (the request, the signatures, Begär granskning).
    def reviewer = @reviewer

    # open: ->(obj) { { have:, need: } while a review is asked and not yet decided, else nil } (the flag "granskning
    # begärd, väntar på n av m"); withdraw: ->(obj, user) { takes the open review back } (the step was moved after the
    # person said yes to the question)
    def register_reviewer(plugin:, approved:, changed:, partial: nil, open: nil, withdraw: nil, possible: nil)
      @reviewer = { plugin: plugin.to_s, approved: approved, changed: changed, partial: partial, open: open, withdraw: withdraw, possible: possible }
    end

    # May this thing be reviewed here (possible: ->(obj) { true or false }, the reviewer's own rule, such as a project
    # with the module on)? Where it may not, the box has no locked Verifierad step and no line about the review
    def reviewable?(obj)
      return false unless reviewer

      fn = reviewer[:possible]
      fn ? !!fn.call(obj) : true
    rescue StandardError
      false
    end

    # The open review's counts, or nil
    def open_review(obj)
      fn = reviewer && reviewer[:open]
      fn ? fn.call(obj) : nil
    rescue StandardError => e
      Rails.logger.warn("[gk_records] open review not asked for #{obj.class.name} #{obj&.id}: #{e.class} #{e.message}")
      nil
    end

    # Who last set the status and when, for the quiet words after the pill: [time, user or nil]; nil without a row
    def set_by(obj)
      r = row(obj)
      return nil unless r && r.status != NONE

      [r.set_at, r.set_by_id && ::User.find_by(id: r.set_by_id)]
    end

    def reviewed?(obj)
      !!(reviewer && reviewer[:approved].call(obj))
    rescue StandardError => e
      Rails.logger.warn("[gk_records] review not asked for #{obj.class.name} #{obj&.id}: #{e.class} #{e.message}")
      false
    end

    # Verified, and the content changed after the approving review: derived when shown, never stored. Only where the
    # place sets verified through the review: where it is set by hand there is no review to be changed since (a thing
    # verified by a review before its place went over to by hand shows no flag it could never clear)
    def changed_since_review?(obj, status = :ask)
      status = get(obj) if status == :ask
      return false unless reviewer && Ladder.review_flag?(status, review_locked?(obj))

      reviewer[:changed].call(obj) ? true : false
    rescue StandardError
      false
    end

    # The text the badge and the column show, in the place's words: "Verifierad, ändrad sedan granskningen" when it
    # changed after the review
    def shown_label(obj, status = :ask)
      status = get(obj) if status == :ask
      return '' if status.nil? || status.to_s == NONE

      pl = place(obj)
      return label(status, place: pl) unless changed_since_review?(obj, status)

      word = label('verified', place: pl)
      word == i18n(:label_gk_records_verification_verified) ? ::I18n.t(:label_gk_records_verification_changed) : ::I18n.t(:label_gk_records_verification_changed_step, step: word)
    end

    # ------------------------------------------------------------------ the content a review is bound to
    # The text that is hashed for a review: what the place's owner registers (register_content), for an issue its
    # subject and description, an assessment what it holds. A target whose owner says nothing cannot be verified at
    # all: never "all its columns", since a column a plugin adds later would make every review of it stand as changed.
    def contents = (@contents ||= {})

    # The facts as "name=value", in the order given, one per line of the hash
    def facts_text(obj, names) = names.map { |n| "#{n}=#{obj.public_send(n)}" }.join("\u0000")

    def content(obj)
      t = Targets.for_object(obj)
      fn = t && contents[t.key]
      fn ? fn.call(obj).to_s : nil
    end

    # May the thing be verified at all: a registered target whose content is chosen
    def verifiable?(obj)
      t = obj && Targets.for_object(obj)
      t ? contents.key?(t.key) : false
    end

    # ------------------------------------------------------------------ where the row is
    def tracker_ids
      s = ::Setting.plugin_gk_records
      Array(s.is_a?(Hash) ? s['verification_tracker_ids'] : nil).map(&:to_i).reject(&:zero?).uniq
    rescue StandardError
      []
    end

    def tracker?(tracker_id) = tracker_ids.include?(tracker_id.to_i)

    # A package that brings its own tracker chooses it (project_types' Källa); true when it was not chosen before
    def choose_tracker!(tracker_id)
      id = tracker_id.to_i
      return false if id.zero? || tracker?(id)

      now = ::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records.dup : {}
      ::Setting.plugin_gk_records = now.merge('verification_tracker_ids' => (tracker_ids + [id]).map(&:to_s))
      true
    end

    # Whether the thing has the row: the function on, and for an issue a tracker the administrator chose
    def shown?(obj)
      return false unless obj&.id && feature? && ready? && verifiable?(obj)

      obj.is_a?(::Issue) ? tracker?(obj.tracker_id) : true
    end

    # The thing an assessment is about (nil for an assessment of a note, which is no target)
    def assessed(assessment)
      Targets.resolve("#{assessment.target_type}:#{assessment.target_id}")&.last
    end

    # Whoever may change the thing: an issue's editable attributes, an assessment's thing, else the owner's rule
    def may_set?(obj, user = ::User.current)
      return false unless user&.logged?

      case obj
      when ::Issue then obj.attributes_editable?(user)
      when ::GkRecordsAssessment then (t = assessed(obj)) ? may_set?(t, user) : user.admin?
      else Targets.editable?(obj, user)
      end
    end

    # ------------------------------------------------------------------ setting
    # A person's choice on the page: a level that is on at the thing's place, verified only where the place does not
    # lock it to the review, or none; the reason by the place records.verification. [true, nil] or [false, message].
    # While a review is open, moving the step asks first (the code OPEN_REVIEW, [false, question, code]); with
    # withdraw: true the open review is taken back by the reviewer and the step is set
    def change(obj, status, user: ::User.current, reason: nil, withdraw: false)
      return [false, ::I18n.t(:error_gk_records_verification_not_here, title: title(place(obj)))] unless shown?(obj)
      return [false, ::I18n.t(:error_gk_records_verification_permission)] unless may_set?(obj, user)

      st = status.to_s.presence || NONE
      pl = place(obj)
      case Ladder.refusal(st, levels_for(obj), review_locked?(obj))
      when :unknown then return [false, ::I18n.t(:error_gk_records_verification_unknown)]
      when :review_only then return [false, ::I18n.t(:error_gk_records_verification_review_only, step: label('verified', place: pl))]
      when :level_off then return [false, ::I18n.t(:error_gk_records_verification_level_off, step: label(st, place: pl))]
      end

      check = Reasons.check(REASON, reason)
      return [false, check.error] unless check.ok

      now = get(obj) || NONE
      if st != now && (open = open_review(obj))
        return [false, ::I18n.t(:text_gk_records_verification_withdraw_question, have: open[:have], need: open[:need]), OPEN_REVIEW] unless withdraw

        reviewer[:withdraw]&.call(obj, user)
      end
      set!(obj, st, user: user, reason: check.text)
      [true, nil]
    end

    # The row a review is about, made with no status when there is none (a review may be asked before any status is
    # set); making it is no change of the status, so no event
    def ensure_row!(obj)
      t = Targets.for_object(obj)
      raise ArgumentError, "#{obj.class.name} is not a registered records target" unless t
      raise ArgumentError, "#{obj.class.name}: no content is chosen for a review (register_content)" unless verifiable?(obj)

      ::GkRecordsVerification.find_or_create_by!(target_type: t.key, target_id: obj.id) do |r|
        r.status = NONE
        r.set_at = ::Time.current
      end
    end

    # Sets the status (nothing happens when it is already that); returns the row, or nil when nothing was there to
    # clear. nil, '' or none clears it. Any step of the ladder, whatever the place has on (scenarios and moves). The
    # event says before and after (nil for none); the reason is a note of kind reason on the thing (Events.write).
    # verified is refused where the place locks it to the review, unless the content as it is now has an approved
    # review. notify: false writes an issue's history entry without mail (a move).
    def set!(obj, status, user: ::User.current, reason: nil, origin: nil, notify: true)
      status = status.to_s.presence || NONE
      raise ArgumentError, "verification status #{status} is not known" unless LADDER.include?(status)

      t = Targets.for_object(obj)
      raise ArgumentError, "#{obj.class.name} is not a registered records target" unless t
      raise ArgumentError, "#{obj.class.name}: no content is chosen for a review (register_content)" unless verifiable?(obj)
      if status == 'verified' && review_locked?(obj) && !reviewed?(obj)
        raise Refused, ::I18n.t(:error_gk_records_verification_review_only, step: label('verified', place: place(obj)))
      end

      who = user&.logged? ? user : nil
      after = status == NONE ? nil : status
      ::GkRecordsVerification.transaction do
        r = ::GkRecordsVerification.lock.find_or_initialize_by(target_type: t.key, target_id: obj.id)
        before = r.persisted? && r.status != NONE ? r.status : nil
        next(r.persisted? ? r : nil) if before == after

        r.assign_attributes(status: status, set_by_id: who&.id, set_at: ::Time.current, reason: reason.to_s.strip.presence)
        r.save!
        Events.write(obj, EVENT, details: { status: [before, after] }, reason: reason.to_s.strip.presence, user: who,
                                 origin: origin || (who ? 'human' : 'system'))
        journal!(obj, before, after, reason, who, notify: notify)
        r
      end
    end

    # On an issue the change also stands in its history, as core's own changes do: a row in Ändrade egenskaper and the reason as the entry's note
    JOURNAL_PROPERTY = 'gk_records'
    JOURNAL_KEY = 'verification'

    def journal!(obj, before, after, reason, who, notify: true)
      return unless obj.is_a?(::Issue)

      j = ::Journal.new(journalized: obj, user: who || ::User.anonymous, notes: reason.to_s.strip)
      j.notify = false unless notify
      j.details << ::JournalDetail.new(property: JOURNAL_PROPERTY, prop_key: JOURNAL_KEY, old_value: before, value: after)
      j.save!
      j
    end

    # The row in the history: "Verifieringsstatus ändrad från Hypotes till Delvis verifierad", in the reader's language
    # and the words of the issue's tracker now. core_stuff's register journal_detail (property gk_records, prop_key
    # verification), so every other detail stays core's. The row is drawn by the one that asks core's show_detail (a
    # view, or a controller with IssuesHelper), as before: line is bound to it.
    module HistoryLine
      def self.call(detail, view, no_html, options) = instance_method(:line).bind_call(view, detail, no_html, options)

      def self.register!
        unless defined?(::GkCoreStuff::JournalDetails::PluginDsl)
          ::Rails.logger.warn("[gk_records] gk_core_stuff is missing, although it is required: the line Verification in an issue's history is core's own")
          return
        end

        ::Redmine::Plugin.find(:gk_records).journal_detail property: Verification::JOURNAL_PROPERTY, prop_key: Verification::JOURNAL_KEY,
                                                           renderer: self
      end

      def line(detail, no_html = false, _options = {})
        pl = begin
          Verification.place(detail.journal&.journalized)
        rescue StandardError
          nil
        end
        label = Verification.title(pl)
        old = Verification.label(detail.old_value, place: pl).presence
        new = Verification.label(detail.value, place: pl).presence
        unless no_html
          label = content_tag('strong', label)
          # from and to as GK GUI Stuff's pills with a dot in their roles, only to read
          pill = ->(value, word) { gk_gui_stuff_pill(word, role: Verification.role(value), dot: true) }
          old = pill.call(detail.old_value, old) if old
          new = pill.call(detail.value, new) if new
        end
        s = if new && old then l(:text_journal_changed, label: label, old: old, new: new).html_safe
            elsif new then l(:text_journal_set_to, label: label, value: new).html_safe
            else l(:text_journal_deleted, label: label, old: no_html ? old : content_tag('del', old)).html_safe
            end
        return s if no_html

        # the mark the page's script finds, so the entry's note is drawn as records' reason
        content_tag('span', s, class: 'gk-records-journal-verification', data: { reason_label: l(:label_gk_records_note_reason) })
      end
    end

    # The row's reason in the reader's language when it was a system text (SystemText): the reason of the latest
    # change, when that is the row's reason; otherwise the row's reason as written
    def reason_text(row)
      return nil if row.reason.blank?

      ev = ::GkRecordsEvent.for_target(row.target_type, row.target_id).where(kind: EVENT).order(:id).last
      n = ev&.reason_note
      n && n.body == row.reason ? n.shown_body : row.reason
    rescue StandardError
      row.reason
    end

    # ------------------------------------------------------------------ the issue list
    # The statuses of many issues in one query, kept on each issue for the column
    def preload(issues)
      list = Array(issues).select { |i| i.is_a?(::Issue) }
      return if list.empty? || !ready?

      have = ::GkRecordsVerification.where(target_type: 'issue', target_id: list.map(&:id)).pluck(:target_id, :status).to_h
      list.each { |i| i.instance_variable_set(:@gk_records_verification, have[i.id] == NONE ? nil : have[i.id]) }
    end

    def query_column? = feature? && ready? && tracker_ids.any?

    # The place an issue list speaks for: the tracker its filter is locked to (with verification), else the issue
    # default, as the column's caption and the filter's values do when the list mixes trackers
    def list_place(query)
      tid = Ladder.list_tracker(query.respond_to?(:filters) ? query.filters : nil)
      tid && tracker?(tid) ? Ladder.tracker_place(tid) : 'issue'
    end

    # The filter's values: the levels of the trackers (one tracker's when the list is locked to it), in the words of
    # that place; Verifierad only where a plugin reviews when it is locked to the review; Ingen status last
    def filter_values(query)
      pl = list_place(query)
      lv = if pl == 'issue'
             Ladder.ordered(tracker_ids.flat_map { |t| levels(Ladder.tracker_place(t)) })
           else
             levels(pl)
           end
      lv -= ['verified'] if !reviewer && place_locked?(pl)
      (lv - [NONE]).map { |s| [label(s, place: pl), s] } + [[pill_label(nil, place: pl), NONE]]
    end

    module IssueValue
      # The column Verifieringsstatus: the status as text in the words of the issue's tracker, changed since the review
      # when it is. This is the value CSV and PDF get (core's csv_value); the HTML list draws the pill through ColumnPill.
      def gk_records_verification
        st = gk_records_verification_status
        st ? Verification.shown_label(self, st) : nil
      end

      # The stored status (preloaded for a list), nil when none is said
      def gk_records_verification_status
        instance_variable_defined?(:@gk_records_verification) ? @gk_records_verification : Verification.get(self)
      end
    end

    # The column in the HTML issue list: the status as its pill
    # without ▾, through a formatter of its own on QueriesHelper#column_value (core patch, documented in patches.rb, as
    # gk_tags does). CSV and PDF go through core's csv_value and get the word; every other column stays core's.
    module ColumnPill
      def column_value(column, item, value)
        return super unless column.name == :gk_records_verification && item.is_a?(::Issue)

        st = item.gk_records_verification_status
        st ? gk_records_verification_badge(item, status: st) : ''
      end
    end

    module IssueQueryPatch
      def issues(options = {})
        list = super
        Verification.preload(list) if Verification.query_column?
        list
      end

      # The caption is the issue default's row name when the list mixes trackers, the tracker's when the filter is
      # locked to one
      def available_columns
        cols = super
        if Verification.query_column? && cols.none? { |c| c.name == :gk_records_verification }
          order = Verification::ORDER.map { |k, n| "WHEN '#{k}' THEN #{n}" }.join(' ')
          sort = "COALESCE((SELECT CASE v.status #{order} ELSE 5 END FROM #{::GkRecordsVerification.table_name} v " \
                 "WHERE v.target_type = 'issue' AND v.target_id = #{::Issue.table_name}.id), 5)"
          query = self
          cols << ::QueryColumn.new(:gk_records_verification, caption: -> { Verification.title(Verification.list_place(query)) }, sortable: sort)
        end
        cols
      end

      # The levels and Ingen status as a value of its own; the values are read when the filter is drawn, so they follow
      # the tracker filter as the caption does. The filter asks on the keys.
      def initialize_available_filters
        super
        return unless Verification.query_column?

        query = self
        add_available_filter 'gk_records_verification', type: :list_optional, name: Verification.title('issue'), remote: false,
                                                      values: -> { Verification.filter_values(query) }
      end

      # = and ! a status among the four or none (no row, or cleared), * any status said, !* none
      def sql_for_gk_records_verification_field(_field, operator, value)
        conn = ::GkRecordsVerification.connection
        ids = lambda do |list|
          "#{::Issue.table_name}.id IN (SELECT v.target_id FROM #{::GkRecordsVerification.table_name} v WHERE v.target_type = 'issue' " \
            "AND v.status IN (#{list.map { |s| conn.quote(s) }.join(', ')}))"
        end
        asked = Array(value).map(&:to_s)
        vals = asked & Verification::STATUSES
        none = asked.include?(NONE)
        # the issues a choice of statuses (and perhaps none) holds
        hit = lambda do
          parts = []
          parts << ids.call(vals) unless vals.empty?
          parts << "NOT (#{ids.call(Verification::STATUSES)})" if none
          parts.empty? ? '1=0' : "(#{parts.join(' OR ')})"
        end
        case operator
        when '=' then hit.call
        when '!' then vals.empty? && !none ? '1=1' : "NOT #{hit.call}"
        when '*' then ids.call(Verification::STATUSES)
        when '!*' then "NOT (#{ids.call(Verification::STATUSES)})"
        else '1=0'
        end
      end
    end

    # ------------------------------------------------------------------ the tracker's own page
    # The checkbox Verifieringsstatus on Administration > Trackers, New and Edit, through core's hook, and under it the
    # levels of the tracker's place, all saved with the tracker's own Save: the controller patch checks the levels
    # before core saves anything, keeps the choice in records' setting verification_tracker_ids after the tracker is
    # saved, and then carries out the levels.
    def set_tracker!(tracker_id, on)
      id = tracker_id.to_i
      return false if id.zero? || tracker?(id) == on

      ids = on ? tracker_ids + [id] : tracker_ids - [id]
      now = ::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records.dup : {}
      ::Setting.plugin_gk_records = now.merge('verification_tracker_ids' => ids.map(&:to_s))
      true
    end

    # Core patch (documented): TrackersController#create and #update. The posted levels are checked first; when
    # something is missing nothing is saved, and core's own form is drawn again (core's new or edit, as core does
    # after a failed save) with the posted choices and the error in the flash.
    module TrackersControllerPatch
      def create
        plans = gk_records_levels_checked(:new)
        return unless plans

        super
        Verification.keep_tracker_choice(@tracker, params)
        Verification.keep_tracker_levels(@tracker, params, plans, flash)
      end

      def update
        plans = gk_records_levels_checked(:edit)
        return unless plans

        super
        Verification.keep_tracker_choice(@tracker, params)
        Verification.keep_tracker_levels(@tracker, params, plans, flash)
      end

      private

      # The plans of the posted levels, or nil after the form was drawn again with what is missing
      def gk_records_levels_checked(action)
        plans, errors = Verification.check_tracker_levels(params)
        return plans if errors.empty?

        flash.now[:error] = Verification.levels_refused(errors)
        @tracker = action == :new ? ::Tracker.new : ::Tracker.find(params[:id])
        @tracker.safe_attributes = params[:tracker]
        action == :new ? new : edit
        render action: action.to_s
        nil
      end
    end

    def keep_tracker_choice(tracker, params)
      return unless tracker&.persisted? && params.key?(:gk_records_verification) && tracker.errors.empty?

      set_tracker!(tracker.id, params[:gk_records_verification].to_s == '1')
    rescue StandardError => e
      Rails.logger.warn("[gk_records] the tracker's verification status not kept: #{e.message}")
    end

    # The place a tracker's form posts its levels under: its own, or NEW_TRACKER_PLACE before it is created
    def tracker_form_place(id) = id.to_i.positive? ? Ladder.tracker_place(id) : NEW_TRACKER_PLACE

    # [plans, errors] for the tracker's posted levels; none while the tracker's check box Verifieringsstatus is off
    def check_tracker_levels(params)
      raw = params[LEVELS_PARAM]
      return [{}, []] if raw.blank? || params[:gk_records_verification].to_s != '1'

      check_levels(raw, only: [tracker_form_place(params[:id])])
    end

    # After the tracker was saved with verification status on: its levels carried out (a new tracker's under its id)
    def keep_tracker_levels(tracker, _params, plans, flash)
      return if plans.blank? || !(tracker&.persisted? && tracker.errors.empty? && tracker?(tracker.id))

      ok, error = apply_levels!(plans, rename: { NEW_TRACKER_PLACE => Ladder.tracker_place(tracker.id) }, saved: true)
      flash[:error] = error unless ok
    rescue StandardError => e
      # the tracker is saved; the administrator is told that its levels were not
      Rails.logger.warn("[gk_records] the tracker's verification levels not kept: #{e.class} #{e.message}")
      broken = ::I18n.t(:error_gk_records_vlevels_move_failed, why: ::I18n.t(:text_gk_records_vlevels_move_broken))
      flash[:error] = ::I18n.t(:error_gk_records_vlevels_saved_not_moved, errors: broken)
    end

    class TrackerHooks < Redmine::Hook::ViewListener
      include GkRecords::Gate::Listener # silent without GK GUI Stuff (gate.rb)
      # on every issue page, also when the row is no longer on for the tracker: earlier entries keep their look
      def view_issues_show_description_bottom(_context = {}) = javascript_include_tag('gk_records_journal', plugin: 'gk_records')

      # The tracker's check box Verifieringsstatus, at the end of the tracker's attribute box through core's hook there
      # (view_trackers_form_bottom, gk_core_stuff's form_hooks, issue #44660); without that hook the box is not drawn
      # and the trackers are chosen on records' settings page. Nothing on core's form is looked for. Under it the
      # levels of the tracker's place as plain check boxes saved with the tracker, also for a tracker not created yet;
      # shown while the check box is ticked (the levels' script follows it). A form drawn again after a refused save
      # keeps what was posted.
      def view_trackers_form_bottom(context = {})
        return '' unless User.current.admin?

        tracker = context[:tracker]
        saved = tracker&.persisted? ? true : false
        sent = context[:controller].respond_to?(:params) ? context[:controller].params : nil
        on = if sent&.key?(:gk_records_verification)
               sent[:gk_records_verification].to_s == '1'
             else
               saved && Verification.tracker?(tracker.id)
             end
        place = Verification.tracker_form_place(saved ? tracker.id : nil)
        box = content_tag('p', safe_join([
                                           label_tag('gk_records_verification', Verification.title(saved ? place : 'issue')),
                                           hidden_field_tag('gk_records_verification', '0', id: nil),
                                           check_box_tag('gk_records_verification', '1', on, id: 'gk_records_verification'),
                                           content_tag('em', ::I18n.t(:text_gk_records_verification_tracker), class: 'info')
                                         ]))
        view = context[:hook_caller]
        return box unless view.respond_to?(:render)

        levels = content_tag('div', view.render(partial: 'gk_records/verification_levels', locals: { place: place }),
                             hidden: !on, class: 'gk-records-vlevels-follow', data: { gk_records_vlevels_follow: 'gk_records_verification' })
        safe_join([box, levels])
      end
    end

    # The tracker's box Verifieringsstatus (core's hook); the patches are applied with the others (Patches.apply!)
    def register_hooks!
      Redmine::Hook.add_listener(TrackerHooks) unless Redmine::Hook.listeners.any?(TrackerHooks)
    end

    # ------------------------------------------------------------------ the assessment as a target
    # So an assessment can carry a status and its events. Never changed (an assessment is kept whole), so no notes and
    # no links are made on it here; seen by whoever may see the thing assessed.
    def register_assessment_target!
      Targets.register('gk_records_assessment', model: 'GkRecordsAssessment',
                                             visible: ->(a, user) { (t = assessed(a)) ? Targets.visible?(t, user) : user.admin? },
                                             editable: ->(_a, _user) { false },
                                             linkable: ->(_a, _user) { false },
                                             label: ->(a) { "#{::I18n.t(:label_gk_records_assessment)}: #{a.display_title}" },
                                             url: lambda { |a|
                                               { controller: 'gk_records_assessments', action: 'page', target: "#{a.target_type}:#{a.target_id}",
                                                 anchor: "gk-records-assessment-#{a.id}" }
                                             })
    end
  end
end
