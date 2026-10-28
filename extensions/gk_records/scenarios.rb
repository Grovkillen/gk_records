# frozen_string_literal: true

module GkRecords
  # records' own step and expectations in scenarios: notes on the scenario's objects with a reply, a correction
  # and a voiding, and links between them, written as the person the scenario names. Texts come from the locale
  # (records.notes.<key>.body,.void_reason). A note is found again by target, kind and text, a link by its two
  # ends and kind, so create can run again.
  # Events are never written here: only the owner plugins write events (P1), so the scenario expects the ones
  # people, triggers and workflow_rules wrote.
  module Scenarios
    # target: {group: support_team} and the like (never the key "on": YAML reads it as true): the object by the
    # scenario's key. In the step it is what the run made; in a check it is found by its name.
    # {organization: key} and {person: key} name people's registers.
    FINDERS = {
      'group' => ->(sc, key) { ::Group.givable.where(lastname: sc.t(:groups, key, :name)).order(:id).first },
      'trigger' => ->(sc, key) { defined?(::GkTriggersTrigger) ? ::GkTriggersTrigger.where(name: sc.t(:triggers, key, :name)).order(:id).first : nil },
      'rule' => ->(sc, key) { defined?(::GkWorkflowRulesRule) ? ::GkWorkflowRulesRule.where(name: sc.t(:rules, key, :name)).order(:id).first : nil },
      'issue' => lambda { |sc, key|
        i = sc.list(:issues).detect { |x| x['key'] == key }
        p = i && sc.list(:projects).detect { |x| x['key'] == i['project'] }
        p && ::Issue.where(project_id: ::Project.where(identifier: p['identifier']).select(:id)).where(subject: sc.t(:issues, key, :subject)).order(:id).first
      },
      # People's organizations and persons by the scenario's keys, as people's step finds them again (an organization by
      # its name; a person with an account by the account, another by her name without an account). Every finder by a
      # name takes the oldest row: a quick contact or an import may make another with the same name, and without an order
      # the database may give either (it did after people's migration 034 rewrote the organizations)
      'organization' => lambda { |sc, key|
        defined?(::GkPeopleOrganization) ? ::GkPeopleOrganization.where(name: sc.t(:people, :organizations, key, :name)).order(:id).first : nil
      },
      'person' => lambda { |sc, key|
        next nil unless defined?(::GkPeoplePerson) && defined?(::GkPeople) && ::GkPeople.respond_to?(:person_for)

        row = Array((sc.data['people'] || {})['persons']).detect { |x| x['key'] == key.to_s }
        account = row ? row['user'] : key.to_s
        u = account && sc.list(:users).detect { |x| x['key'] == account.to_s }
        if u
          user = ::User.find_by(login: u['login'])
          user && ::GkPeople.person_for(user)
        elsif row
          ::GkPeoplePerson.where(first_name: sc.t(:people, :persons, key, :first_name), last_name: sc.t(:people, :persons, key, :last_name), user_id: nil).order(:id).first
        end
      },
      # An assessment the step records_assessments made, by its key (its source names the scenario and the key), so a
      # verification, a review or a count can point at it
      'assessment' => ->(sc, key) { ::GkRecordsAssessment.where(origin_source_id: Scenarios.assessment_source(sc, key)).order(:id).last }
    }.freeze

    module_function

    def object(scenario, on)
      kind, key = on.to_a.first
      obj = FINDERS[kind.to_s]&.call(scenario, key)
      raise ::GkScenarios::Error, ::I18n.t(:error_gk_scenarios_ref, kind: kind, key: key) unless obj

      obj
    end

    def ref(scenario, on)
      obj = object(scenario, on)
      t = Targets.for_object(obj) or raise ::GkScenarios::Error, "#{obj.class.name} is not a records target"
      [t.key, obj.id]
    end

    def section(scenario, name) = Array((scenario.data['records'] || {})[name.to_s])

    # The source an assessment made by the step carries (found again by it)
    def assessment_source(scenario, key) = "gk_scenarios:#{scenario.id}:#{key}"

    # A text in every language the scenario has (locales/<lang>.yml), { lang => text }; the scenario's own language
    # must have it (Scenario#t raises otherwise), the others are taken when they are there
    def texts_in_all(scenario, *path)
      scenario.t(*path)
      Dir[File.join(scenario.dir, 'locales', '*.yml')].sort.each_with_object({}) do |f, out|
        lang = File.basename(f, '.yml')
        data = (YAML.safe_load(File.read(f, encoding: 'UTF-8')) || {})[lang]
        v = path.map(&:to_s).reduce(data) { |h, k| h.is_a?(Hash) ? h[k] : nil }
        out[lang] = v.to_s.strip if (v.is_a?(String) || v.is_a?(Numeric)) && v.to_s.strip.present?
      end
    end

    # A person sets a verification status on a thing the way the row Verifieringsstatus does (Verification.change: who
    # may change the thing, the reason place records.verification, never Verifierad). Found again: an event of that
    # status by the person on the thing after the one the previous row of the scenario matched (cursor), so a scenario
    # may set one status after another on the same thing and a review afterwards is left as it is. at: days from today,
    # the event, its reason and the row dated then. Returns [the event or the row, created].
    def verify_as!(ctx, obj, status, by:, reason:, label:, at: nil, cursor: {})
      key = Targets.for_object(obj)&.key or raise ::GkScenarios::Error, "#{label}: #{obj.class.name} is not a records target"
      want = status.to_s == Verification::NONE ? nil : status.to_s
      if want == 'verified'
        raise ::GkScenarios::Error, "#{label}: #{::I18n.t(:error_gk_records_verification_review_only)} (signoff: reviews)"
      end

      mark = [key, obj.id]
      scope = ::GkRecordsEvent.where(target_type: key, target_id: obj.id, kind: Verification::EVENT)
      done = scope.where(user_id: by.id).where('id > ?', cursor[mark].to_i).order(:id).detect { |ev| Array(ev.details_hash['status']).last == want }
      if done
        cursor[mark] = done.id
        return [done, false]
      end

      last = ::GkRecordsEvent.maximum(:id).to_i
      ok, err = ctx.as(by) { Verification.change(obj, want, user: by, reason: reason) }
      raise ::GkScenarios::Error, "#{label}: #{err}" unless ok

      ev = scope.where('id > ?', last).order(:id).last
      return [Verification.row(obj), false] unless ev # it had that status already

      if at
        t = ctx.day(at).in_time_zone + 12.hours
        ev.update_columns(created_at: t)
        ::GkRecordsNote.where(id: ev.reason_note_id).update_all(created_at: t) if ev.reason_note_id
        Verification.row(obj)&.update_columns(set_at: t)
        # the entry in an issue's history gets the same day (Verification.journal!)
        if obj.is_a?(::Issue)
          ::Journal.where(journalized: obj).joins(:details).where(journal_details: { property: Verification::JOURNAL_PROPERTY })
                   .order(:id).last&.update_columns(created_on: t, updated_on: t)
        end
      end
      cursor[mark] = ev.id
      [ev, true]
    ensure
      Reasons::Current.reset if defined?(Reasons::Current)
    end

    def note_for(scenario, key)
      n = section(scenario, :notes).detect { |x| x['key'] == key } or return nil
      type, id = ref(scenario, n['target'])
      ::GkRecordsNote.for_target(type, id).where(kind: n['kind'] || 'comment', body: scenario.t(:records, :notes, key, :body)).order(:id).first
    end

    # What records_identity checks, [[name, ok],...]; called inside a transaction that is rolled back
    def identity_checks(ctx, e, part)
      sc = ctx.scenario
      here = Identity.instance_id
      by = e['as'] || e['by']
      actor = by ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, by)) : ::User.active.where(admin: true).order(:id).first
      raise ::GkScenarios::Error, "records_identity: no user #{by}" unless actor

      case part
      when 'new_issue'
        base = object(sc, { 'issue' => (e['like'] || sc.list(:issues).first&.dig('key')).to_s })
        made = Array.new(2) do |n|
          ctx.as(actor) do
            i = ::Issue.new
            i.copy_from(base, attachments: false, subtasks: false, watchers: false, link: false)
            i.subject = "#{base.subject} (#{n + 1})"
            i.status ||= base.tracker.default_status
            i.save!
            i
          end
        end
        rows = made.map { |i| ::GkRecordsIdentity.for_target(Identity.target_of(i)&.key, i.id).first }
        gids = rows.map { |r| r&.gid.to_s }
        [['gid on create', rows.all?],
         ['UUID version 7', gids.all? { |g| Identity.uuid7?(g) }],
         ['unique', gids.uniq.size == 2 && gids.all? { |g| ::GkRecordsIdentity.where(gid: g).count == 1 }],
         ['time first', gids[1][0, 13] >= gids[0][0, 13]],
         ['find', made.each_with_index.all? { |i, n| Identity.find(gids[n]) == i }],
         ['origin', rows.all? { |r| r&.origin_instance.presence == here }],
         ['owner', rows.all? { |r| r&.owner_instance.presence == here }]]
      when 'change_owner'
        obj = object(sc, e['target'] || { 'issue' => sc.list(:issues).first&.dig('key') })
        r0 = Identity.row(obj) or raise ::GkScenarios::Error, "records_identity: #{obj.class.name} is not a records target"
        gid0 = r0.gid
        origin0 = r0.origin_instance
        owner0 = r0.owner_instance.presence
        other = Identity.uuid7
        last = ::GkRecordsEvent.maximum(:id).to_i
        ev = ctx.as(actor) { Identity.change_owner!(obj, other, reason: 'scenario', user: actor) }
        r1 = ::GkRecordsIdentity.find(r0.id)
        again = ctx.as(actor) { Identity.change_owner!(obj, other, reason: 'scenario', user: actor) }
        try = ::GkRecordsIdentity.find(r0.id)
        try.origin_instance = Identity.uuid7
        [['event', ev.is_a?(::GkRecordsEvent) && ev.kind == Identity::EVENT && ev.user_id == actor.id &&
          Array(ev.details_hash['owner_instance']) == [owner0, other] && ev.details_hash['gid'] == gid0],
         ['reason', ev.respond_to?(:reason_text) && ev.reason_text == 'scenario'],
         ['owner', r1.owner_instance == other],
         ['origin kept', r1.origin_instance == origin0],
         ['gid kept', r1.gid == gid0],
         ['same owner again writes nothing', again.nil? && ::GkRecordsEvent.where('id > ?', last).where(kind: Identity::EVENT).count == 1],
         ['origin never changed', origin0.present? ? !try.valid? : true],
         ['never deleted', !::GkRecordsIdentity.find(r0.id).destroy && ::GkRecordsIdentity.exists?(r0.id)]]
      when 'backfill'
        key = (e['target_type'] || 'issue').to_s
        t = Targets.find(key) or raise ::GkScenarios::Error, "records_identity: no target #{key}"
        things = t.model_class.unscoped.count
        # taken away inside the transaction only, to see the backfill make them again
        ::GkRecordsIdentity.where(target_type: key).delete_all
        made = Identity.backfill!
        rows = ::GkRecordsIdentity.where(target_type: key)
        gids = rows.order(:target_id).pluck(:gid)
        made_again = Identity.backfill!
        [["every thing (#{things})", things.positive? && rows.count == things && rows.distinct.count(:target_id) == things],
         ['made', made >= things],
         ['UUID version 7', gids.all? { |g| Identity.uuid7?(g) }],
         ['unique', gids.uniq.size == gids.size],
         ['origin', rows.pluck(:origin_instance).map(&:presence).uniq == [Identity.claim_origin]],
         ['again makes none', made_again.zero? && rows.order(:target_id).pluck(:gid) == gids]]
      else
        [['part', false]]
      end
    end

    # What records_system_text checks, [[name, ok],...]; called inside a transaction that is rolled back. The key is
    # records' own text_gk_records_docimp_link_reason with its value reading; a locale change is simulated with
    # I18n.backend.store_translations and put back by the caller (texts).
    SYSTEM_TEXT_KEY = :text_gk_records_docimp_link_reason

    def system_text_checks(ctx, e, part, texts)
      sc = ctx.scenario
      st = SystemText
      key = SYSTEM_TEXT_KEY
      values = { 'reading' => 'Scenario, CSV' }
      by = e['by'] || e['as']
      actor = by ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, by)) : ::User.active.where(admin: true).order(:id).first
      raise ::GkScenarios::Error, "records_system_text: no user #{by}" unless actor

      obj = object(sc, e['target'] || section(sc, :notes).first&.dig('target') || {})
      want = ->(l, tpl = nil) { st.interpolate(tpl || st.template(key, l), values) }
      shown = ->(n, l) { ::I18n.with_locale(l) { n.reload.shown_body } }
      rows = -> { ::GkRecordsTextRevision.where(key: key.to_s) }
      sys = Notes.write(obj, kind: 'comment', text_key: key, text_values: values, user: nil)
      locales = st.templates(key).keys
      case part
      when 'readers'
        human = Notes.write(obj, kind: 'comment', body: 'Scenario: skrivet av en människa', user: actor)
        [['key kept', sys.text_key == key.to_s && st.parse_values(sys.text_values) == values && sys.origin == 'system'],
         ['sv and en', (%w[sv en] - locales).empty?],
         ['Swedish reader', shown.call(sys, :sv) == want.call('sv')],
         ['English reader', shown.call(sys, :en) == want.call('en')],
         ['fallback body', sys.body == want.call(st.default_locale) && sys.body.present?],
         ['one row per locale', locales.all? { |l| rows.call.where(locale: l).count >= 1 }],
         ['a second note adds no row', (n = rows.call.count) && Notes.write(obj, kind: 'comment', text_key: key, text_values: values) && rows.call.count == n],
         ['human note as written', human.text_key.nil? && shown.call(human, :en) == human.body && shown.call(human, :sv) == human.body],
         ['human note has no key in REST', !human.as_api_json(actor).key?(:text_key) && human.as_api_json(actor)[:body] == human.body],
         ['nothing now', sys.body_now.nil?]]
      when 'changed'
        changed = e['locale'].to_s.presence || 'sv'
        others = locales - [changed]
        old_text = want.call(changed)
        old_others = others.to_h { |l| [l, want.call(l)] }
        before = rows.call.group(:locale).count
        tpl = "#{st.template(key, changed)} (ändrad i scenariot)"
        texts[changed] = st.template(key, changed)
        ::I18n.backend.store_translations(changed.to_sym, { key => tpl })
        added = st.ensure_current!(key)
        after = rows.call.group(:locale).count
        again = st.ensure_current!(key)
        fresh = Notes.write(obj, kind: 'comment', text_key: key, text_values: values)
        new_text = want.call(changed, tpl)
        [['one row added', added.size == 1 && added.first.locale == changed && after[changed].to_i == before[changed].to_i + 1],
         ['other locales none', others.all? { |l| after[l].to_i == before[l].to_i }],
         ['again none', again.empty?],
         ['old note old text', shown.call(sys, changed) == old_text],
         ['old note others unchanged', others.all? { |l| shown.call(sys, l) == old_others[l] }],
         ['text now beside it', ::I18n.with_locale(changed) { sys.reload.body_now } == new_text],
         ['new note new text', shown.call(fresh, changed) == new_text && ::I18n.with_locale(changed) { fresh.body_now }.nil?],
         ['REST text_now', ::I18n.with_locale(changed) { sys.as_api_json(actor)[:text_now] } == new_text],
         ['rows never changed', !added.first.update(body: 'x') && !added.first.destroy]]
      else
        [['part', false]]
      end
    end

    def register!
      # The assessment kinds kept in records' settings are emptied with the instance, as their history in the events is
      # (scenarios' generic Wipe.clear_setting)
      ::GkScenarios::Wipe.clear_setting(:gk_records, AssessmentKinds::SETTING) if ::GkScenarios::Wipe.respond_to?(:clear_setting)
      # the export log's step and expectations (scenarios_export_log.rb)
      register_export_log!
      # The reasons' modes the scenario needs (records: { reason_modes: { all: places } }; all is the installation),
      # before every other step, so that what the other plugins' steps write keeps its reason: a new installation has
      # reasons off (records_1021-SID-24), and the plugins' own reason rules are tried with each place's default
      ::GkScenarios::Steps.register('records_reason_modes', plugin: :gk_records, order: 5) do |ctx|
        modes = ((ctx.scenario.data['records'] || {})['reason_modes'])
        next unless modes.is_a?(Hash)

        # the modes are kept in memory for a while (Reasons.stored), and emptying the instance does not know them: read
        # what the table says now, or a mode from before the emptying is taken as still set
        Reasons.forget!

        changed = modes.map do |k, m|
          key = k.to_s == 'all' ? Reasons::ALL : k.to_s
          now = key == Reasons::ALL ? Reasons.installation_mode : Reasons.own_mode(key)
          next false if now == m.to_s

          Reasons.set_mode!(key, m.to_s)
          true
        end.any?
        ctx.note(:rec_reason_modes, 'reason_modes', nil, changed)
      end
      ::GkScenarios::Steps.register('records', plugin: :gk_records, order: 350) do |ctx|
        sc = ctx.scenario
        # Emptying the instance takes the identities too, but keeps accounts and settings; they and anything else made
        # without the hook get theirs again here (the things the scenario made have theirs already)
        Identity.fill_origin!
        ctx.note(:rec_identities, 'backfill', nil, Identity.backfill!.positive?)
        # Settings the scenario needs, since a new installation has some off (records: {
        # settings: { mark_restricted_people: "1" } })
        if (want = (sc.data['records'] || {})['settings']).is_a?(Hash) && want.any?
          now = ::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records.dup : {}
          diff = want.transform_values(&:to_s).reject { |k, v| now[k.to_s].to_s == v }
          ::Setting.plugin_gk_records = now.merge(diff.transform_keys(&:to_s)) if diff.any?
          ctx.note(:rec_settings, 'settings', nil, diff.any?)
        end
        # The functions the organisation uses, turned on as the administrator would (records: { features: [events,
        # readings] }; GkRecords::Features, off for a new installation)
        if (want_f = (sc.data['records'] || {})['features']).is_a?(Array) && want_f.any?
          now = ::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records.dup : {}
          have = now['features'].is_a?(Hash) ? now['features'].dup : {}
          add = want_f.map(&:to_s).reject { |k| have[k].to_s == '1' }
          ::Setting.plugin_gk_records = now.merge('features' => have.merge(add.to_h { |k| [k, '1'] })) if add.any?
          ctx.note(:rec_features, 'features', nil, add.any?)
        end
        # The trackers whose issues have the row Verifieringsstatus, added to what is chosen (records: {
        # verification_trackers: [feature] })
        if (keys = (sc.data['records'] || {})['verification_trackers'])
          changed = Array(keys).map { |k| Verification.choose_tracker!(ctx.get(:tracker, k).id) }.any?
          ctx.note(:rec_verification_trackers, 'trackers', nil, changed)
        end
        section(sc, :notes).each do |n|
          existing = note_for(sc, n['key'])
          if existing
            ctx.note(:rec_note, n['key'], existing, false)
            next
          end
          type, id = ref(sc, n['target'])
          by = ctx.get(:user, n['by'])
          note = ::GkRecordsNote.new(target_type: type, target_id: id, kind: n['kind'] || 'comment', body: sc.t(:records, :notes, n['key'], :body),
                                  user_id: by.id, origin: 'human')
          note.parent_id = ctx.get(:rec_note, n['reply_to']).id if n['reply_to']
          note.save!
          if n['corrects']
            ::GkRecordsLink.create!(source_type: 'gk_records_note', source_id: note.id, target_type: 'gk_records_note',
                                 target_id: ctx.get(:rec_note, n['corrects']).id, kind: 'corrects', user_id: by.id)
          end
          note.void!(ctx.get(:user, n['voided_by']), sc.t(:records, :notes, n['key'], :void_reason)) if n['voided_by']
          ctx.note(:rec_note, n['key'], note, true)
        end
        section(sc, :links).each do |l|
          st, sid = ref(sc, l['from'])
          tt, tid = ref(sc, l['to'])
          kind = l['kind'] || 'manual'
          link = ::GkRecordsLink.find_by(source_type: st, source_id: sid, target_type: tt, target_id: tid, kind: kind)
          created = link.nil?
          # a link by hand says why (link_semantics): the text is records.links.<key>.reason
          reason = Kinds.find(:link, kind)&.manual ? sc.t(:records, :links, l['key'], :reason) : nil
          link ||= ::GkRecordsLink.create!(source_type: st, source_id: sid, target_type: tt, target_id: tid, kind: kind, reason: reason,
                                        user_id: ctx.get(:user, l['by']).id)
          ctx.note(:rec_link, l['key'], link, created)
        end
      end

      # rec_day: a day as the reader counts it. The event log's date filter begins the day at midnight in her zone and
      # ends it at 23:59:59 (as core's filters), an event at 00:30 her time is inside it, and a reading's date in its
      # label is her day. Meant to run with in_zone, far from the server.
      ::GkScenarios::Expect.register('rec_day') do |_ctx, _e|
        user = ::User.current
        today = user.today
        zone = user.time_zone
        failed = []
        controller = ::GkRecordsEventsController.new
        first = controller.send(:day_start, today)
        last = controller.send(:day_end, today)
        midnight = zone ? zone.local(today.year, today.month, today.day) : ::Time.local(today.year, today.month, today.day)
        failed << "day_start (#{first})" unless first == midnight
        failed << "day_end (#{last})" unless last == midnight.end_of_day
        at = midnight + 30.minutes
        failed << 'event_inside' unless (first..last).cover?(at)
        failed << 'time_to_date' unless user.time_to_date(at) == today
        label = Readings.label(::GkRecordsReading.new(source_label: 'scenario', read_at: at))
        failed << "reading_label (#{label})" unless label.include?(today.iso8601)
        { 'ok' => failed.empty?, 'want' => "the reader's day #{today.iso8601}", 'got' => failed.empty? ? "the reader's day #{today.iso8601}" : "not: #{failed.join(', ')}" }
      end

      # rec_instant: the event log's created_at keeps the instant with its zone (migration 002). Two events in the
      # hour that comes twice the night summer time ends (00:30Z and 01:30Z on 25 October 2026, both 02:30 Swedish
      # time), the later one written first, read back as the instants they were and in that order, and the log's
      # date filter finds both on the reader's day. Rolled back.
      ::GkScenarios::Expect.register('rec_instant') do |_ctx, _e|
        failed = []
        first = ::Time.utc(2026, 10, 25, 0, 30)
        second = ::Time.utc(2026, 10, 25, 1, 30)
        ::ActiveRecord::Base.transaction do
          make = ->(at) { ::GkRecordsEvent.create!(target_type: 'scenario', target_id: 0, kind: 'scenario_instant', created_at: at) }
          later = make.call(second)
          earlier = make.call(first)
          rows = ::GkRecordsEvent.where(id: [later.id, earlier.id]).order(:created_at, :id).to_a
          failed << 'order' unless rows.map(&:id) == [earlier.id, later.id]
          failed << "read_back (#{rows.map { |r| r.created_at.getutc.iso8601 }.join(' ')})" unless rows.map { |r| r.created_at.getutc } == [first, second]
          day = ::User.current.time_to_date(first)
          q = ::GkRecordsEventQuery.new(name: 'scenario')
          q.filters = {}
          q.add_filter('created_at', '=', [day.iso8601])
          found = q.results_scope.where(id: [later.id, earlier.id]).pluck(:id)
          failed << "filter_day (#{day.iso8601})" unless found.sort == [later.id, earlier.id].sort
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => failed.empty?, 'want' => 'two instants in the doubled hour, in order', 'got' => failed.empty? ? 'two instants in the doubled hour, in order' : "not: #{failed.join(', ')}" }
      end

      # rec_origin_instant: notes, links, assessments, readings and origin keep their times with their zone (migrations
      # 001, 003, 004, 006 and 007). For each table the scenario's first row and a copy of it are moved into the hour
      # that comes twice the night summer time ends (00:30Z and 01:30Z on 25 October 2026, both 02:30 Swedish time),
      # the lower id to the later one, and read back as the instants they were and in that order. A field origin's copy
      # gets a field of its own (one per field); an assessment is made when the scenario has none. Rolled back.
      ::GkScenarios::Expect.register('rec_origin_instant') do |_ctx, _e|
        failed = []
        first = ::Time.utc(2026, 10, 25, 0, 30)
        second = ::Time.utc(2026, 10, 25, 1, 30)
        tables = [[::GkRecordsNote, %i[created_at voided_at]], [::GkRecordsLink, %i[created_at voided_at]], [::GkRecordsAssessment, %i[assessed_at]],
                  [::GkRecordsReading, %i[read_at source_time]], [::GkRecordsFieldOrigin, %i[set_at]]]
        ::ActiveRecord::Base.transaction do
          tables.each do |model, cols|
            base = model.order(:id).first
            # basic has no assessment (framtid_bracke has): one is made here, inside the transaction, so the table is
            # always tried
            if base.nil? && model == ::GkRecordsAssessment
              base = model.new(target_type: 'scenario', target_id: 0, kind: 'scenario_instant', assessed_at: second, origin: 'human', created_at: ::Time.current)
              base.save!(validate: false)
            end
            (failed << "#{model.name}: none") && next unless base

            copy = base.dup
            copy.field = "#{base.field}_scenario_copy" if copy.respond_to?(:field=)
            copy.save!(validate: false)
            base.update_columns(cols.index_with { second })
            copy.update_columns(cols.index_with { first })
            rows = model.where(id: [base.id, copy.id]).order(cols.first, :id).to_a
            failed << "#{model.name} order" unless rows.map(&:id) == [copy.id, base.id]
            cols.each do |c|
              got = rows.map { |r| r.public_send(c)&.getutc }
              failed << "#{model.name}.#{c} (#{got.map { |t| t&.iso8601 }.join(' ')})" unless got == [first, second]
            end
          end
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => failed.empty?, 'want' => 'two instants in the doubled hour, in order, in each table', 'got' => failed.empty? ? 'two instants in the doubled hour, in order, in each table' : "not: #{failed.join(', ')}" }
      end

      # rec_text_instant: verification statuses and the system texts' revisions keep their times with their zone
      # (migrations 008 and 010). Two statuses set in the hour that comes twice the night summer time ends (00:30Z and
      # 01:30Z on 25 October 2026, both 02:30 Swedish time), the later one written first, are read back as the
      # instants they were and in that order. Two revisions of one text cell hold from those two instants: the text at
      # 00:45Z is the first, at 01:00Z (02:00 the second time) still the first, at 01:45Z the second, and before both
      # the first (a note older than the cell's first row). Rolled back.
      ::GkScenarios::Expect.register('rec_text_instant') do |_ctx, _e|
        failed = []
        first = ::Time.utc(2026, 10, 25, 0, 30)
        second = ::Time.utc(2026, 10, 25, 1, 30)
        ::ActiveRecord::Base.transaction do
          make = ->(id, at) { ::GkRecordsVerification.create!(target_type: 'scenario', target_id: id, status: Verification::STATUSES.first, set_at: at) }
          later = make.call(-2, second)
          earlier = make.call(-1, first)
          rows = ::GkRecordsVerification.where(id: [later.id, earlier.id]).order(:set_at, :id).to_a
          failed << 'verification order' unless rows.map(&:id) == [earlier.id, later.id]
          failed << "verification set_at (#{rows.map { |r| r.set_at.getutc.iso8601 }.join(' ')})" unless rows.map { |r| r.set_at.getutc } == [first, second]

          key = 'gk_records_scenario_text_instant'
          b = ::GkRecordsTextRevision.create!(key: key, locale: 'sv', body: 'B', sha256: SystemText.digest('B'), valid_from: second, created_at: second)
          a = ::GkRecordsTextRevision.create!(key: key, locale: 'sv', body: 'A', sha256: SystemText.digest('A'), valid_from: first, created_at: first)
          got = ::GkRecordsTextRevision.where(id: [a.id, b.id]).order(:valid_from, :id).map { |r| r.valid_from.getutc }
          failed << "valid_from (#{got.map(&:iso8601).join(' ')})" unless got == [first, second]
          { ::Time.utc(2026, 10, 25, 0, 15) => 'A', ::Time.utc(2026, 10, 25, 0, 45) => 'A', ::Time.utc(2026, 10, 25, 1, 0) => 'A',
            ::Time.utc(2026, 10, 25, 1, 45) => 'B' }.each do |at, want|
            body = SystemText.revision_at(key, 'sv', at)&.body
            failed << "text at #{at.iso8601} (#{body.inspect})" unless body == want
          end
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => failed.empty?, 'want' => 'statuses and text revisions in the doubled hour, in order', 'got' => failed.empty? ? 'statuses and text revisions in the doubled hour, in order' : "not: #{failed.join(', ')}" }
      end

      # records_count: notes, events or links on one of the scenario's objects, narrowed by kind (and voided for notes)
      ::GkScenarios::Expect.register('records_count') do |ctx, e|
        type, id = ref(ctx.scenario, e['target'])
        scope = case e['records_count']
                when 'notes'
                  s = ::GkRecordsNote.for_target(type, id)
                  s = e['voided'] ? s.where.not(voided_at: nil) : s.where(voided_at: nil) unless e['voided'].nil?
                  s
                when 'events' then ::GkRecordsEvent.for_target(type, id)
                when 'links' then ::GkRecordsLink.active.touching(type, id)
                when 'assessments' then ::GkRecordsAssessment.for_target(type, id)
                else raise ::GkScenarios::Error, ::I18n.t(:error_gk_scenarios_expect, kind: e['records_count'])
                end
        scope = scope.where(kind: e['kind']) if e['kind']
        got = scope.count
        # neither equals nor at_least: nothing to hold the count against, so it fails
        next({ 'ok' => false, 'want' => 'equals | at_least', 'got' => got.to_s }) unless e.key?('equals') || e.key?('at_least')

        ok = e.key?('equals') ? got == e['equals'].to_i : got >= e['at_least'].to_i
        { 'ok' => ok, 'want' => e.key?('equals') ? e['equals'].to_s : ">= #{e['at_least']}", 'got' => got.to_s }
      end

      # records_link_refused: a link of the kind between two of the scenario's things (or notes: {note: key}) is
      # refused by the model: the same pair again whichever way for a symmetric kind, a circle for an acyclic one
      ::GkScenarios::Expect.register('records_link_refused') do |ctx, e|
        sc = ctx.scenario
        ends = %w[from to].map do |side|
          on = e[side]
          on.key?('note') ? ['gk_records_note', note_for(sc, on['note'])&.id] : ref(sc, on)
        end
        link = ::GkRecordsLink.new(source_type: ends[0][0], source_id: ends[0][1], target_type: ends[1][0], target_id: ends[1][1],
                                kind: e['records_link_refused'], reason: 'scenario')
        ok = !link.valid?
        { 'ok' => ok, 'want' => 'refused', 'got' => ok ? 'refused' : 'allowed' }
      end

      # records_link_targets: a kind registered with targets goes only to those. The kind is the registered manual kind
      # made directed and limited to the sort named (records_link_targets: group), on the links here only, so nothing is
      # registered: from -> to (of that sort) has no complaint about the sort, from -> wrong is refused with
      # "Kopplingen... kan bara gå till...". Nothing is saved (and the check runs in a transaction that is rolled back).
      ::GkScenarios::Expect.register('records_link_targets') do |ctx, e|
        sc = ctx.scenario
        base = Kinds.find(:link, 'manual')
        next({ 'ok' => false, 'want' => 'the kind manual', 'got' => '-' }) unless base

        kind = Kind.new(**base.to_h.merge(symmetric: false, targets: [e['records_link_targets'].to_s].freeze))
        message = ::I18n.t(:error_gk_records_link_targets, kind: kind.label, types: kind.targets_label)
        from = ref(sc, e['from'])
        got = {}
        ::ActiveRecord::Base.transaction do
          { 'to' => e['to'], 'wrong' => e['wrong'] }.each do |side, on|
            other = ref(sc, on)
            link = ::GkRecordsLink.new(source_type: from[0], source_id: from[1], target_type: other[0], target_id: other[1], kind: base.key,
                                    reason: 'scenario')
            link.define_singleton_method(:kind_def) { kind }
            link.valid?
            got[side] = link.errors.full_messages.include?(message) ? 'refused' : 'allowed'
          end
          raise ::ActiveRecord::Rollback
        end
        want = { 'to' => 'allowed', 'wrong' => 'refused' }
        { 'ok' => got == want, 'want' => want.to_json, 'got' => got.to_json }
      end

      # records_link_sources: a kind registered with sources goes only from those. As records_link_targets: the
      # registered manual kind made directed and limited to the sources named (records_link_sources: issue), on the
      # links here only. from (of that sort) -> to has no complaint about the sort, wrong_from -> to is refused with
      # "Kopplingen... kan bara gå från..."; with symmetric: true the same kind without direction is checked as well,
      # where the link from to -> from (an allowed source at the other end) is allowed. Nothing is saved (a transaction
      # that is rolled back).
      ::GkScenarios::Expect.register('records_link_sources') do |ctx, e|
        sc = ctx.scenario
        base = Kinds.find(:link, 'manual')
        next({ 'ok' => false, 'want' => 'the kind manual', 'got' => '-' }) unless base

        sorts = [e['records_link_sources'].to_s].freeze
        kind = Kind.new(**base.to_h.merge(symmetric: false, targets: nil, sources: sorts))
        message = ::I18n.t(:error_gk_records_link_sources, kind: kind.label, types: kind.sources_label)
        to = ref(sc, e['to'])
        try = lambda do |k, a, b|
          link = ::GkRecordsLink.new(source_type: a[0], source_id: a[1], target_type: b[0], target_id: b[1], kind: base.key, reason: 'scenario')
          link.define_singleton_method(:kind_def) { k }
          link.valid?
          link.errors.full_messages.include?(message) ? 'refused' : 'allowed'
        end
        got = {}
        want = { 'from' => 'allowed', 'wrong_from' => 'refused' }
        ::ActiveRecord::Base.transaction do
          got['from'] = try.call(kind, ref(sc, e['from']), to)
          got['wrong_from'] = try.call(kind, ref(sc, e['wrong_from']), to)
          if e['symmetric']
            both = Kind.new(**base.to_h.merge(symmetric: true, targets: nil, sources: sorts))
            got['symmetric_reversed'] = try.call(both, to, ref(sc, e['from']))
            want['symmetric_reversed'] = 'allowed'
          end
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => got == want, 'want' => want.to_json, 'got' => got.to_json }
      end

      # records_note: what holds for one note: corrected_by another, a reply to another, voided with a reason, written by
      ::GkScenarios::Expect.register('records_note') do |ctx, e|
        sc = ctx.scenario
        note = note_for(sc, e['records_note'])
        next { 'ok' => false, 'want' => 'note', 'got' => '-' } unless note

        checks = []
        if e['corrected_by']
          other = note_for(sc, e['corrected_by'])
          checks << ['corrected_by', other && note.corrected_by.include?(other)]
        end
        if e['reply_to']
          other = note_for(sc, e['reply_to'])
          checks << ['reply_to', other && note.parent_id == other.id]
        end
        checks << ['voided', note.voided? && note.void_reason&.body.present? && note.voided_by&.login == ::GkScenarios::Expect.login(ctx, e['voided_by'])] if e['voided_by']
        checks << ['by', note.user&.login == ::GkScenarios::Expect.login(ctx, e['by'])] if e['by']
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
      end

      # records_user_shown: is the person who did the latest event of a kind (on one of the scenario's objects when
      # target is given) named to the scenario's user in as, or shown as "en person du inte får se". An event with
      # no person hides nobody and counts as shown.
      ::GkScenarios::Expect.register('records_user_shown') do |ctx, e|
        scope = ::GkRecordsEvent.where(kind: e['records_user_shown'].to_s)
        if e['target']
          type, id = ref(ctx.scenario, e['target'])
          scope = scope.for_target(type, id)
        end
        event = scope.order(:id).last
        viewer = e['as'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
        next({ 'ok' => false, 'want' => 'event, as', 'got' => event ? 'no user in as' : 'no event' }) unless event && viewer
        next({ 'ok' => false, 'want' => 'equals: true | false', 'got' => '-' }) unless e.key?('equals')

        got = Visibility.visible_user?(event.user, viewer)
        want = e['equals'].to_s == 'true'
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # records_events_open (1.01.000): may the scenario's user in as open the event log of one of the scenario's projects
      # (project:, the tab Händelser) or, without project:, the log under Administration (GkRecordsEvent.log_for);
      # equals: true | false
      ::GkScenarios::Expect.register('records_events_open') do |ctx, e|
        viewer = e['records_events_open'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['records_events_open']))
        project = e['project'] && ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['project'])).first
        next({ 'ok' => false, 'want' => 'a user (and a project)', 'got' => '-' }) unless viewer && (project || !e['project'])

        got = !::GkRecordsEvent.log_for(viewer, project: project).nil?
        want = !e.key?('equals') || e['equals'].to_s == 'true'
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # records_events_csv (1.01.000): the event log as the scenario's user in records_events_csv reads it (project:
      # the tab, else the log under Administration) written as CSV: one row per event the user sees, a byte order mark,
      # the time in ISO 8601 with the zone and the language's separator. at_least: the rows there must be at least.
      ::GkScenarios::Expect.register('records_events_csv') do |ctx, e|
        viewer = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['records_events_csv']))
        project = e['project'] && ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['project'])).first
        scope = viewer && ::GkRecordsEvent.log_for(viewer, project: project)
        next({ 'ok' => false, 'want' => 'a user who may open the log', 'got' => viewer ? 'may not open it' : 'no user' }) unless scope

        events = scope.limit(::Setting.issues_export_limit.to_i).to_a
        text = nil
        ctx.as(viewer) { text = EventsCsv.generate(events, viewer) }
        sep = ::I18n.t(:general_csv_separator, default: ',')
        rows = ::CSV.parse(text.delete_prefix(EventsCsv::BOM), col_sep: sep)
        checks = []
        checks << 'bom' unless text.start_with?(EventsCsv::BOM)
        checks << "rows #{rows.size - 1} != #{events.size}" unless rows.size - 1 == events.size
        checks << "at_least #{e['at_least']}" if e['at_least'] && events.size < e['at_least'].to_i
        checks << 'iso time' if events.any? && rows[1][0] !~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/
        { 'ok' => checks.empty?, 'want' => "#{events.size} rows, BOM, ISO time, separator #{sep.inspect}", 'got' => checks.empty? ? 'ok' : checks.join(', ') }
      end

      # records_detail_shown: does the name of the scenario's user in person stand in the details of the latest event
      # of a kind (on one of the scenario's objects when target is given) as shown to the scenario's user in as. The
      # details are read as the event log shows them, so a name written in plain text by an older writer counts as
      # shown.
      # name: instead of person, the text itself, for a person who is no user.
      ::GkScenarios::Expect.register('records_detail_shown') do |ctx, e|
        scope = ::GkRecordsEvent.where(kind: e['records_detail_shown'].to_s)
        if e['target']
          type, id = ref(ctx.scenario, e['target'])
          scope = scope.for_target(type, id)
        end
        event = scope.order(:id).last
        viewer = e['as'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
        person = e['person'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['person']))
        name = e['name'].to_s.presence || person&.name
        unless event && viewer && name
          next({ 'ok' => false, 'want' => 'event, as, person or name', 'got' => event ? 'no user in as, person or name' : 'no event' })
        end
        next({ 'ok' => false, 'want' => 'equals: true | false', 'got' => '-' }) unless e.key?('equals')

        got = event.changes_text(viewer).include?(name)
        want = e['equals'].to_s == 'true'
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # records_assessment_user_shown: is the person who made a frozen assessment named to the scenario's user in as,
      # or shown as "en person du inte får se". The value is the thing assessed, as in target ({issue: k2}; a bare key
      # is an issue). rule: the scenario's rule that made it (workflow_rules record_assessment, found by its source),
      # or kind: the assessment kind; with neither, any assessment on the thing. The newest counts, as the first row of
      # the tab Bedömningar, and the test is the one that tab makes (gk_records_user: Visibility.visible_user?).
      # Whether as may see the thing itself is not asked here. An assessment with no person (the system) hides nobody
      # and counts as shown.
      ::GkScenarios::Expect.register('records_assessment_user_shown') do |ctx, e|
        on = e['records_assessment_user_shown']
        on = { 'issue' => on } unless on.is_a?(Hash)
        type, id = ref(ctx.scenario, on)
        scope = ::GkRecordsAssessment.for_target(type, id)
        if e['rule']
          rule = FINDERS['rule'].call(ctx.scenario, e['rule'])
          unless rule && defined?(::GkWorkflowRules::Types::RecordAssessment)
            next({ 'ok' => false, 'want' => 'rule', 'got' => "no rule #{e['rule']}" })
          end

          scope = scope.where(origin_source_id: ::GkWorkflowRules::Types::RecordAssessment.source(rule))
        end
        scope = scope.where(kind: e['kind'].to_s) if e['kind']
        assessment = scope.newest_first.first
        viewer = e['as'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
        next({ 'ok' => false, 'want' => 'assessment, as', 'got' => assessment ? 'no user in as' : 'no assessment' }) unless assessment && viewer
        next({ 'ok' => false, 'want' => 'equals: true | false', 'got' => '-' }) unless e.key?('equals')

        got = Visibility.visible_user?(assessment.user, viewer)
        want = e['equals'].to_s == 'true'
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # records_restricted: does the scenario's user in as see the mark "syns inte för alla" on the scenario's user
      # named.
      # equals: true when as may see the person and some other active user may not (Visibility.restricted_info, with
      # the setting mark_restricted_people as it stands); hidden_from: N, when given, is how many may not.
      ::GkScenarios::Expect.register('records_restricted') do |ctx, e|
        person = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['records_restricted']))
        viewer = e['as'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
        next({ 'ok' => false, 'want' => 'person, as', 'got' => person ? 'no user in as' : 'no person' }) unless person && viewer
        next({ 'ok' => false, 'want' => 'equals: true | false', 'got' => '-' }) unless e.key?('equals')

        info = Visibility.restricted_info(person, viewer)
        want = e['equals'].to_s == 'true'
        ok = info[:restricted] == want
        ok &&= info[:hidden_from] == e['hidden_from'].to_i if want && e.key?('hidden_from')
        wanted = want && e.key?('hidden_from') ? "true, hidden_from #{e['hidden_from']}" : want.to_s
        got = info[:restricted] ? "true, hidden_from #{info[:hidden_from]}" : 'false'
        { 'ok' => ok, 'want' => wanted, 'got' => got }
      end

      # records_setting_logged: a change of one of records' own settings (the value is the key, such as note_max_length)
      # is in the settings' history: an event setting_changed on the setting with the key's before and after. by: the
      # scenario's user who makes the change, with the scenario's reason (records.settings.<expectation key>.reason), so
      # the event is hers and the reason has her as its sender and a time. Without by: the change is made with no
      # person, and the event is the system's (no user, origin system, shown as "systemet"). The change and its event
      # are made in a transaction that is rolled back, so the instance's settings and history stay as they were and no
      # listener (triggers, after commit) is told.
      ::GkScenarios::Expect.register('records_setting_logged') do |ctx, e|
        key = e['records_setting_logged'].to_s
        actor = e['by'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by']))
        next({ 'ok' => false, 'want' => 'by', 'got' => "no user #{e['by']}" }) if e['by'] && !actor
        next({ 'ok' => false, 'want' => 'a setting key', 'got' => '-' }) if key.empty?

        reason = actor ? ctx.scenario.t(:records, :settings, e['key'], :reason) : nil
        result = nil
        begin
          ::GkRecordsEvent.transaction(requires_new: true) do
            before = ::Setting.plugin_gk_records[key].to_s
            after = case before
                    when '1' then '0'
                    when '0' then '1'
                    else before.match?(/\A\d+\z/) ? (before.to_i + 1).to_s : "#{before} scenario"
                    end
            last_id = ::GkRecordsEvent.maximum(:id).to_i
            ctx.as(actor || ::User.anonymous) do
              SettingsHistory.with_reason(reason) do
                ::Setting.plugin_gk_records = ::Setting.plugin_gk_records.to_h.merge(key => after)
              end
            end
            event = ::GkRecordsEvent.where(kind: SettingsHistory::KIND, target_type: SettingsHistory::TARGET)
                                 .where('id > ?', last_id).order(:id).last
            checks = [['event', !event.nil?]]
            if event
              d = event.details_hash
              checks << ['setting', d['setting'] == 'plugin_gk_records']
              checks << ['before and after', d[key] == [before, after]]
              if actor
                note = event.reason_note
                checks << ['by', event.user_id == actor.id && event.origin == 'human']
                checks << ['reason', note && note.body == reason && note.user_id == actor.id && note.created_at.present?]
              else
                checks << ['system', event.user_id.nil? && event.origin == 'system']
              end
            end
            failed = checks.reject { |_k, ok| ok }.map(&:first)
            result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '),
                       'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
            raise ::ActiveRecord::Rollback
          end
        ensure
          # the cached value is the one rolled back: read again from the database
          ::Setting.clear_cache if ::Setting.respond_to?(:clear_cache)
        end
        result || { 'ok' => false, 'want' => 'event', 'got' => '-' }
      end
      
      # records_reason_modes: the reasons' modes on one place (the value is the place's key, such as records.note_void),
      # as the scenario's user (by:, who must be an administrator): off keeps no reason even when one is sent; optional
      # keeps what is written and nothing when empty; required refuses empty, and a suggestion (the person's latest
      # reason) that was not chosen counts as empty; the installation's Av, Valfritt or Krävs locks every place, and a
      # place's own mode counts only with Varje ställes förval; a change from required to off is an event that says so; a #123 in the reason becomes
      # a link from the reason to the issue. All in a transaction that is rolled back, so the instance's modes and
      # history stay as they were.
      ::GkScenarios::Expect.register('records_reason_modes') do |ctx, e|
        key = e['records_reason_modes'].to_s
        # by: a scenario user who is an administrator; without it the instance's first active administrator
        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        next({ 'ok' => false, 'want' => 'by, an administrator', 'got' => "no administrator #{e['by']}" }) unless actor&.admin?
      
        r = Reasons
        place = r.find(key)
        next({ 'ok' => false, 'want' => 'a place that is not fixed', 'got' => key }) if place.nil? || place.fixed
      
        issue = ::Issue.order(:id).first
        next({ 'ok' => false, 'want' => 'an issue to mention', 'got' => '-' }) unless issue
      
        result = nil
        begin
          ::GkRecordsEvent.transaction(requires_new: true) do
            checks = []
            ctx.as(actor) do
              # the place's own modes count only while the installation is on Varje ställes förval (PLACES)
              r.set_mode!(r::ALL, r::PLACES, reason: 'scenario')
              r.set_mode!(key, 'off', reason: 'scenario')
              c = r.check(key, 'skickat ändå')
              checks << ['off keeps nothing', c.ok && c.text.nil?]
              r.set_mode!(key, 'optional', reason: 'scenario')
              c1 = r.check(key, '')
              c2 = r.check(key, ' ett skäl ')
              checks << ['optional', c1.ok && c1.text.nil? && c2.ok && c2.text == 'ett skäl']
              r.set_mode!(key, 'inherit', reason: 'scenario')
              checks << ['inherit is the default', r.mode(key) == place.default]
              # records_1022-SID-01: the installation's mode locks the places, also one with its own mode
              r.set_mode!(key, 'optional', reason: 'scenario')
              r.set_mode!(r::ALL, 'required', reason: 'scenario')
              checks << ['installation locks', r.mode(key) == 'required' && r.locked?]
              r.set_mode!(r::ALL, r::PLACES, reason: 'scenario')
              checks << ['own mode again', r.mode(key) == 'optional' && !r.locked?]
              r.set_mode!(key, 'required', reason: 'scenario')
              checks << ['required refuses empty', !r.check(key, '  ').ok]
              last_id = ::GkRecordsEvent.maximum(:id).to_i
              mention = "Prov enligt ##{issue.id}"
              r.set_mode!(key, 'off', reason: mention)
              ev = ::GkRecordsEvent.where(kind: r::KIND).where('id > ?', last_id).order(:id).last
              checks << ['lowered is an event', ev && ev.details_hash['now'] == %w[required off] && ev.user_id == actor.id]
              link = ev && ::GkRecordsLink.active.find_by(kind: r::LINK, source_type: 'gk_records_note', source_id: ev.reason_note_id,
                                                      target_type: 'issue', target_id: issue.id)
              checks << ['#123 is a link', !link.nil?]
              # the person's latest reason for the place is the suggestion, and it does not count until chosen
              ::GkRecords::Reasons::Current.key = key
              r.set_mode!(key, 'required', reason: 'scenario')
              latest = r.suggestions(key, actor)[:latest]
              checks << ['suggestion offered', latest == 'scenario']
              checks << ['suggestion not chosen is empty', !r.check(key, '').ok]
            end
            failed = checks.reject { |_k, ok| ok }.map(&:first)
            result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
            raise ::ActiveRecord::Rollback
          end
        ensure
          r.forget!
          ::GkRecords::Reasons::Current.reset
        end
        result || { 'ok' => false, 'want' => 'modes', 'got' => '-' }
      end

      # records_reading: made | refused | unlisted | dialect | no_file. A reading keeps facts about its file, never the
      # file, and its manifest trimmed to the keys that describe the source.
      # * made: the file's name, size and SHA-256 in the list and no attachment anywhere on a reading; source, format,
      #   source id and time from its manifest's entry, retrieved and mapping; that manifest without the computer, the
      #   errors or a path; a field's pointer with its source, source time and the value's SHA-256 (not the value), and
      #   unchanged? true until the value changes;
      # * refused: a sha256 that is not the file's; unlisted: a manifest that does not list the file; dialect: the old
      #   keys (filer, fil); each refused with no reading made;
      # * no_file: a reading without files has an empty list.
      # In a transaction that is rolled back.
      ::GkScenarios::Expect.register('records_reading') do |ctx, e|
        part = e['records_reading'].to_s
        parts = %w[made refused unlisted dialect no_file]
        next({ 'ok' => false, 'want' => parts.join(' | '), 'got' => part }) unless parts.include?(part)

        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        next({ 'ok' => false, 'want' => 'a user', 'got' => '-' }) unless actor

        bytes = "\xEF\xBB\xBFkommun_kod;cfarNr;orgNr;benamning\n9999;10000001;5560000201;Provbolaget Exempel AB\n".b
        sum = Digest::SHA256.hexdigest(bytes)
        name = 'arbetsstallen_9999_20261005.csv'
        entry = { 'file' => "C:/prov/ut/#{name}", 'kind' => 'arbetsställen', 'source' => 'Provkällan för inläsningar',
                  'format' => 'CSV; semikolon; UTF-8 med BOM', 'source_ref' => 'kommun 9999', 'source_time' => '2026-10-05T06:00:00+02:00',
                  'rows' => 1, 'size' => bytes.bytesize, 'sha256' => part == 'refused' ? ('0' * 64) : sum }
        manifest = { 'script' => 'Scb.ps1', 'computer' => 'PROVDATOR', 'errors' => ['påhittat fel'], 'retrieved' => '2026-10-06T07:00:00+02:00',
                     'files' => [entry] }
        manifest = manifest.merge('files' => [entry.merge('file' => 'annan_fil.csv')]) if part == 'unlisted'
        manifest = { 'skript' => 'Scb.ps1', 'filer' => [{ 'fil' => name, 'sha256' => sum }] } if part == 'dialect'
        result = nil
        ::GkRecordsReading.transaction(requires_new: true) do
          before = ::GkRecordsReading.count
          checks = []
          ctx.as(actor) do
            case part
            when 'made'
              r = Readings.start!(target_type: e['target_type'] || 'organization', source_label: 'given label', route: 'file', format: 'csv',
                                  user: actor, files: [{ bytes: bytes, filename: name }], manifest: manifest, mapping: 'scenario_csv@1',
                                  selection: { 'by' => 'municipality', 'values' => ['9999'], 'labels' => { '9999' => 'Provkommunen' } })
              checks << ['source from the entry', r.source_label == 'Provkällan för inläsningar']
              checks << ['format', r.format == 'CSV']
              checks << ['source id', r.source_ref == 'kommun 9999']
              checks << ['source time', r.source_time&.to_date == Date.new(2026, 10, 5)]
              checks << ['files', r.files == [{ 'file' => name, 'size' => bytes.bytesize, 'sha256' => sum }]]
              checks << ['no attachment', !::GkRecordsReading.reflect_on_association(:attachments) &&
                                          ::Attachment.where(container_type: 'GkRecordsReading').none?]
              m = r.manifest
              checks << ['manifest trimmed', m.is_a?(Hash) && !m.key?('computer') && !m.key?('errors') &&
                                             m['files'].all? { |f| f['file'] == name && f['source_ref'] == 'kommun 9999' }]
              checks << ['retrieved', r.retrieved_at == Time.zone.parse('2026-10-06T07:00:00+02:00')]
              checks << ['mapping', r.mapping == 'scenario_csv@1']
              checks << ['selection', r.selection == { 'by' => 'municipality', 'values' => ['9999'], 'labels' => { '9999' => 'Provkommunen' } }]
              checks << ['label', Readings.label(r).start_with?('Provkällan för inläsningar · CSV · ') && Readings.label(r).include?('2026-10-05')]
              issue = ::Issue.visible(actor).order(:id).first
              if issue
                Readings.set!(r, issue, ['subject'], source: 'Provkälla A', source_time: Time.zone.parse('2026-10-04T12:00:00+02:00'),
                              source_id: 'prov-1', selection_key: '9999')
                p = Readings.origin(issue, 'subject')
                checks << ['selection key', p && p[:pointer].selection_key == '9999' &&
                                            Readings.pointed('issue', mappings: ['scenario_csv@1'], selection_keys: ['9999']) == { 'prov-1' => issue.id } &&
                                            Readings.pointed('issue', mappings: ['scenario_csv@1'], selection_keys: ['0000']).empty? &&
                                            Readings.ids_by_source_id('issue', ['prov-1'], mappings: ['scenario_csv@1']) == { 'prov-1' => issue.id }]
                checks << ['pointer source', p && p[:source] == 'Provkälla A' && p[:source_time]&.to_date == Date.new(2026, 10, 4)]
                checks << ['value digest, not the value', p && p[:value_sha256] == Digest::SHA256.hexdigest(issue.subject.to_s.b) &&
                                                          p[:value_sha256] != issue.subject]
                checks << ['pointer label', Readings.label(r, p && p[:pointer]).start_with?('Provkälla A · CSV · ') &&
                                            Readings.label(r, p && p[:pointer]).include?('2026-10-04')]
                # many pointers at once: the same rows as set! would write, one moved and one new
                n = Readings.set_many!(r, [{ obj: issue, fields: %w[subject description], source: 'Provkälla B', selection_key: '9999' }])
                many = Readings.origin(issue, 'description')
                checks << ['many at once', n == 2 && many && many[:source] == 'Provkälla B' && many[:pointer].selection_key == '9999' &&
                                           many[:value_sha256] == Readings.value_digest(issue.description) &&
                                           ::GkRecordsFieldOrigin.where(target_type: 'issue', target_id: issue.id, field: 'subject').count == 1]
                checks << ['unchanged', Readings.unchanged?(issue, 'subject')]
                issue.subject = "#{issue.subject} x"
                checks << ['changed', !Readings.unchanged?(issue, 'subject')]
              else
                checks << ['an issue to point at', false]
              end
            when 'no_file'
              r = Readings.start!(target_type: 'organization', source_label: 'Provsynk', route: 'api', user: actor)
              checks << ['no files', r.files == [] && r.manifest.nil?]
            else
              refused = begin
                Readings.start!(target_type: 'organization', source_label: 'x', user: actor, files: [{ bytes: bytes, filename: name }], manifest: manifest)
                false
              rescue Readings::Refused
                true
              end
              checks << ['refused', refused]
              checks << ['no reading', ::GkRecordsReading.count == before]
            end
          end
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      end

      # records_verification: a thing's verification status set and read back, with its event: { records_verification:
      # true, target: { group: support_team }, by: olle }.
      # None said at first (or what the thing had), unverified set with a reason (an event verification_changed with
      # before and after, the reason as a note, by the person), the same again writes nothing, verified refused without
      # an approved review (nothing written), hypothesis after it, cleared to none (an event with none after, the row
      # kept as none), an unknown status refused, and the row is never deleted. In a transaction that is rolled back.
      ::GkScenarios::Expect.register('records_verification') do |ctx, e|
        sc = ctx.scenario
        obj = object(sc, e['target'])
        key, id = ref(sc, e['target'])
        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        next({ 'ok' => false, 'want' => 'a user', 'got' => '-' }) unless actor

        result = nil
        ::GkRecordsVerification.transaction(requires_new: true) do
          checks = []
          ctx.as(actor) do
            first = Verification.get(obj)
            events = -> { ::GkRecordsEvent.where(target_type: key, target_id: id, kind: Verification::EVENT).order(:id) }
            n0 = events.call.count
            Verification.set!(obj, 'unverified', user: actor, reason: 'Scenariots prov: osäkert')
            ev = events.call.last
            checks << ['unverified', Verification.get(obj) == 'unverified']
            checks << ['event', events.call.count == n0 + 1 && ev&.details_hash&.dig('status') == [first, 'unverified'] && ev&.user_id == actor.id]
            # the reason is a note on a thing that takes notes, and in the event's details on one that does not (an issue:
            # its notes are its journal; Events.write)
            checks << ['reason as a note', (ev&.reason_note_id && ::GkRecordsNote.find_by(id: ev.reason_note_id)&.body == 'Scenariots prov: osäkert') ||
                                           ev&.details_reason == 'Scenariots prov: osäkert']
            Verification.set!(obj, 'unverified', user: actor)
            checks << ['same again writes nothing', events.call.count == n0 + 1]
            refused_verified = begin
              Verification.set!(obj, 'verified', user: actor)
              false
            rescue Verification::Refused
              true
            end
            checks << ['verified refused without review', refused_verified && Verification.get(obj) == 'unverified' && events.call.count == n0 + 1]
            Verification.set!(obj, 'hypothesis', user: actor)
            checks << ['hypothesis', Verification.get(obj) == 'hypothesis' && events.call.last&.details_hash&.dig('status') == %w[unverified hypothesis]]
            Verification.set!(obj, nil, user: actor)
            checks << ['cleared', Verification.get(obj).nil? && Verification.row(obj)&.status == Verification::NONE &&
                                  events.call.last&.details_hash&.dig('status') == ['hypothesis', nil]]
            Verification.set!(obj, 'hypothesis', user: actor)
            refused = begin
              Verification.set!(obj, 'maybe', user: actor)
              false
            rescue ArgumentError
              true
            end
            checks << ['unknown refused', refused && Verification.get(obj) == 'hypothesis']
            row = Verification.row(obj)
            checks << ['never deleted', row && !row.destroy && ::GkRecordsVerification.exists?(row.id)]
          end
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => 'verification', 'got' => '-' }
      end

      # records_verification_row: does the thing have the row Verifieringsstatus (an issue only on a tracker the
      # administrator chose): { records_verification_row: i5, equals: true }. A bare key is an issue.
      ::GkScenarios::Expect.register('records_verification_row') do |ctx, e|
        on = e['records_verification_row']
        on = { 'issue' => on } unless on.is_a?(Hash)
        obj = object(ctx.scenario, on)
        want = e.key?('equals') ? e['equals'].to_s == 'true' : true
        got = Verification.shown?(obj)
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # records_verification_query: the issue list's filter Verifieringsstatus finds the issue by the status by sets: {
      # records_verification_query: i5, status: hypothesis, by: olle }. The filter = finds it,! and none (!*) leave it
      # out, any (*) finds it, and the list sorted by the column shows the status. Rolled back.
      ::GkScenarios::Expect.register('records_verification_query') do |ctx, e|
        issue = object(ctx.scenario, { 'issue' => e['records_verification_query'] })
        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        status = (e['status'] || 'hypothesis').to_s
        next({ 'ok' => false, 'want' => 'a user', 'got' => '-' }) unless actor

        result = nil
        ::GkRecordsVerification.transaction(requires_new: true) do
          checks = []
          ctx.as(actor) do
            ok, err = Verification.change(issue, status, user: actor)
            checks << ["set #{err}".strip, ok]
            ids = lambda do |op, values = [status]|
              q = ::IssueQuery.new(name: '_')
              q.project = issue.project
              q.filters = {}
              q.add_filter('status_id', '*', [''])
              q.add_filter('gk_records_verification', op, values)
              q.issue_ids
            end
            checks << ['filter offered', ::IssueQuery.new(name: '_').available_filters.key?('gk_records_verification')]
            checks << ['=', ids.call('=').include?(issue.id)]
            checks << ['!', !ids.call('!').include?(issue.id)]
            checks << ['any', ids.call('*', ['']).include?(issue.id)]
            checks << ['none', !ids.call('!*', ['']).include?(issue.id)]
            q = ::IssueQuery.new(name: '_', column_names: %i[subject gk_records_verification])
            q.project = issue.project
            q.filters = {}
            q.add_filter('status_id', '*', [''])
            q.sort_criteria = [%w[gk_records_verification asc]]
            row = q.issues(limit: 500).detect { |i| i.id == issue.id }
            checks << ['column', row && row.gk_records_verification == Verification.label(status)]
          end
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => 'query', 'got' => '-' }
      end

      # records_verification_assessment: an assessment carries a status of its own: one is made on the issue (the first
      # assessment kind registered) and by sets a status on it, with its event on the assessment; verified is refused
      # there too. { records_verification_assessment: i5, by: olle, status: partly_verified }.
      # The value may name any of the scenario's things as a target does ({ organization: c1 }); a bare key is an issue,
      # as before. Rolled back.
      ::GkScenarios::Expect.register('records_verification_assessment') do |ctx, e|
        on = e['records_verification_assessment']
        on = { 'issue' => on } unless on.is_a?(Hash)
        issue = object(ctx.scenario, on)
        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        status = (e['status'] || 'partly_verified').to_s
        kind = Kinds.of(:assessment).first
        next({ 'ok' => false, 'want' => 'a user and an assessment kind', 'got' => '-' }) unless actor && kind

        result = nil
        ::GkRecordsAssessment.transaction(requires_new: true) do
          checks = []
          ctx.as(actor) do
            a = Assessments.record(issue, kind.key, values: [], outcome: 'scenario', user: actor)
            checks << ['row', Verification.shown?(a)]
            checks << ['may set', Verification.may_set?(a, actor)]
            ok, = Verification.change(a, status, user: actor)
            ev = ::GkRecordsEvent.where(target_type: 'gk_records_assessment', target_id: a.id, kind: Verification::EVENT).order(:id).last
            checks << ['set', ok && Verification.get(a) == status && ev&.details_hash&.dig('status') == [nil, status]]
            no, = Verification.change(a, 'verified', user: actor)
            checks << ['verified refused', !no && Verification.get(a) == status]
          end
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => 'assessment', 'got' => '-' }
      end

      # records_documents: Läs in dokument with a made-up zip built here (made-up texts, never real documents): a list
      # of three rows (handbok.txt in the project with a källa, bilagor/rutin.txt in a subproject, saknas.txt missing)
      # and a file no row names (extra.txt). Basic has no subproject and no Dokument module, so the subproject
      # (scn-docimp-sub, under the project, with the person in as as a member with her roles there) and the module are
      # made in the transaction; the källa is a Källa issue made there in source (a project with the source package).
      # Parts
      # * preview: rows found, missing and extra shown with size, SHA-256, project, the default category and the källa
      #   resolved; a källa that is no Källa issue is an error on its row; nothing saved;
      # * stop: an unknown subproject stops the run and nothing is made; a zip kept longer than a day goes with the next
      #   preview;
      # * run: two documents in the right projects with the files as attachments (SHA-256), one reading (route file,
      #   ZIP, the zip's name, size and SHA-256 but no attachment, the list as manifest, counts), the origin pointer with
      #   the file's digest and the label, the event created with edition and date (origin import), and the kept zip
      #   gone;
      # * source: the row with a källa has the link supported_by (origin import, no text) and the other none;
      # * again: the same zip again shows both files as already there, skipped unless chosen, and a run with none chosen
      #   is refused.
      # { records_documents: run, project: improvement, as: olle, source: improvement }. Rolled back.
      # Subproject: one of the scenario's projects under project, where as is a member, takes the place of the
      # subproject made in the transaction (its Dokument module switched on there, rolled back with the rest).
      ::GkScenarios::Expect.register('records_documents') do |ctx, e|
        part = e['records_documents'].to_s
        parts = %w[preview stop run source again]
        next({ 'ok' => false, 'want' => parts.join(' | '), 'got' => part }) unless parts.include?(part)

        imp = DocumentImport
        actor = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as'] || 'olle'))
        project = ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['project'] || 'improvement')).first
        src_project = ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['source'] || e['project'] || 'improvement')).first
        src_tracker = defined?(::GkProjectTypes::Source) ? ::GkProjectTypes::Source.tracker : nil
        given_sub = e['subproject'] && ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['subproject'])).first
        next({ 'ok' => false, 'want' => 'user, projects, the Källa tracker and supported_by', 'got' => '-' }) unless actor && project && src_project && src_tracker && Kinds.find(:link, imp::LINK)
        next({ 'ok' => false, 'want' => "a subproject under #{project.identifier}", 'got' => e['subproject'].to_s }) if e['subproject'] && given_sub&.parent_id != project.id

        require 'zip'
        result = nil
        ::ActiveRecord::Base.transaction(requires_new: true) do
          checks = []
          # what basic lacks: the Dokument module, a subproject with the person as a member, a category, a Källa issue
          project.enabled_module_names = project.enabled_module_names | ['documents']
          if given_sub
            sub = given_sub
            sub.enabled_module_names = sub.enabled_module_names | ['documents']
          else
            sub = ::Project.new(name: 'Dokumentprov underprojekt', identifier: 'scn-docimp-sub', is_public: false)
            sub.enabled_module_names = ['documents']
            sub.save!
            sub.set_parent!(project)
            m = ::Member.new(project: sub, principal: actor)
            m.role_ids = actor.roles_for_project(project).map(&:id)
            m.save!
          end
          ::DocumentCategory.default || ::DocumentCategory.create!(name: 'Dokumentprov', active: true, is_default: true)
          prio = ::IssuePriority.default || ::IssuePriority.active.first
          source = ::Issue.new(project: src_project, tracker: src_tracker, author: actor, subject: 'Dokumentprov källa', priority: prio)
          ctx.as(actor) { source.save! }
          plain = ::Issue.visible(actor).where.not(tracker_id: src_tracker.id).order(:id).first
          actor = ::User.find(actor.id) # the membership above, not a cached one
          project = ::Project.find(project.id)

          zip = lambda do |subproject: sub.identifier, kalla: "##{source.id}"|
            list = "fil;vad det är;varifrån;utgåva;datum;underprojekt;källa;kategori\n" \
                   "handbok.txt;Provhandbok;Leverantören Prov AB;3;2025-05-01;;#{kalla};\n" \
                   "bilagor/rutin.txt;Provrutin;Intern pärm;1;2024-01-15;#{subproject};;\n" \
                   "saknas.txt;Fil som saknas;;;;;;\n"
            files = { 'dokumentlista.csv' => "\xEF\xBB\xBF".b + list.b, 'handbok.txt' => "Påhittad provtext, handboken.\n".b,
                      'bilagor/rutin.txt' => "Påhittad provtext, rutinen.\n".b, 'extra.txt' => "Påhittad fil som ingen rad nämner.\n".b }
            ::Zip::OutputStream.write_buffer(::StringIO.new(+'')) do |zos|
              files.each { |n, data| zos.put_next_entry(n); zos.write(data) }
            end.string.b
          end
          sha = ->(text) { Digest::SHA256.hexdigest(text.b) }
          docs_before = ::Document.count
          readings_before = ::GkRecordsReading.count

          ctx.as(actor) do
            case part
            when 'preview'
              pv = imp.preview(project, zip.call, user: actor)
              r1, r2, r3 = pv[:rows]
              checks << ['three rows', pv[:rows].size == 3]
              checks << ['found', r1['status'] == 'new' && r2['status'] == 'new']
              checks << ['missing', r3['status'] == 'missing' && r3['entry'].nil?]
              checks << ['extra', pv[:extra] == ['extra.txt']]
              checks << ['size and sha', r1['bytes'] == "Påhittad provtext, handboken.\n".b.bytesize && r1['sha256'] == sha.call("Påhittad provtext, handboken.\n")]
              checks << ['projects', r1['project']&.id == project.id && r2['project']&.id == sub.id]
              checks << ['default category', r1['category'] == ::DocumentCategory.default]
              checks << ['source resolved', r1['issue']&.id == source.id]
              checks << ['no stop', !pv[:stop]]
              if plain
                bad = imp.preview(project, zip.call(kalla: "##{plain.id}"), user: actor)[:rows].first
                checks << ['not a source', bad['status'] == 'error' && bad['issue'].nil? && bad['errors'].any?]
              end
              checks << ['nothing saved', ::Document.count == docs_before && ::GkRecordsReading.count == readings_before]
            when 'stop'
              data = zip.call(subproject: 'finns-inte')
              pv = imp.preview(project, data, user: actor)
              checks << ['stops', pv[:stop] && pv[:rows][1]['status'] == 'unknown_project' && pv[:rows][1]['errors'].any?]
              att = imp.keep!(project, data, 'dokument.zip', actor)
              refused = begin
                imp.run!(project, att, user: actor)
                false
              rescue imp::Refused
                true
              end
              checks << ['run refused', refused]
              checks << ['nothing made', ::Document.count == docs_before && ::GkRecordsReading.count == readings_before]
              checks << ['zip kept until discarded', imp.kept(project, att.token, actor) == att]
              att.update_column(:created_on, Time.current - imp::KEEP_FOR - 1.hour)
              fresh = imp.keep!(project, data, 'dokument.zip', actor)
              checks << ['a zip kept longer than a day goes', ::Attachment.find_by(id: att.id).nil? && imp.kept(project, fresh.token, actor) == fresh]
            else
              data = zip.call
              att = imp.keep!(project, data, 'dokument.zip', actor)
              reading, made = imp.run!(project, att, user: actor, source_label: 'Dokumentlista')
              d1 = made.detect { |d| d.project_id == project.id }
              d2 = made.detect { |d| d.project_id == sub.id }
              case part
              when 'run'
                a1 = d1&.attachments&.first
                checks << ['two documents', made.size == 2 && d1 && d2 && ::Document.count == docs_before + 2]
                checks << ['title and description', d1&.title == 'Provhandbok' && d1.description.to_s.include?('Leverantören Prov AB') && d1.description.include?('2025-05-01')]
                checks << ['attachment', a1 && a1.filename == 'handbok.txt' && a1.digest == sha.call("Påhittad provtext, handboken.\n")]
                checks << ['subproject', d2&.attachments&.first&.filename == 'rutin.txt']
                checks << ['reading', reading.route == 'file' && reading.format == 'ZIP' && reading.target_type == imp::TARGET &&
                                      reading.files == [{ 'file' => 'dokument.zip', 'size' => data.bytesize, 'sha256' => sha.call(data) }] &&
                                      ::Attachment.where(container_type: 'GkRecordsReading').none?]
                checks << ['counts', reading.counts['added'] == 2 && reading.counts['rejected'] == 1 && reading.rows == 3]
                checks << ['manifest', reading.manifest.is_a?(Hash) && reading.manifest['rows'].size == 3 && reading.mapping == imp::MAPPING &&
                                       reading.manifest['rows'].first['document'] == d1&.id && reading.manifest['other_files'] == ['extra.txt']]
                o = d1 && Readings.origin(d1, 'file')
                checks << ['origin', o && o[:reading] == reading && o[:source_id] == 'handbok.txt' && o[:value_sha256] == a1&.digest]
                checks << ['label', Readings.label(reading).start_with?('Dokumentlista · ZIP · ')]
                ev = d1 && ::GkRecordsEvent.where(target_type: imp::TARGET, target_id: d1.id, kind: 'created').order(:id).last
                h = ev&.details_hash || {}
                checks << ['event', ev && ev.origin == 'import' && h['reading_id'] == reading.id && h['edition'] == '3' && h['date'] == '2025-05-01' &&
                                    h['sha256'] == a1&.digest && ev.project_id == project.id]
                checks << ['events of the reading', Readings.events(reading, actor).where(kind: 'created').count == 2]
                checks << ['zip gone', ::Attachment.find_by(id: att.id).nil?]
              when 'source'
                l1 = d1 && ::GkRecordsLink.active.find_by(kind: imp::LINK, source_type: imp::TARGET, source_id: d1.id)
                checks << ['link', l1 && l1.target_type == 'issue' && l1.target_id == source.id && l1.origin == 'import' && l1.reason.nil?]
                checks << ['cited', d1 && Links.citations(d1).map(&:target_id) == [source.id]]
                checks << ['none on the other', d2 && !::GkRecordsLink.active.exists?(source_type: imp::TARGET, source_id: d2.id)]
              when 'again'
                again = imp.keep!(project, data, 'dokument.zip', actor)
                pv = imp.preview(project, data, user: actor)
                checks << ['already', pv[:rows][0]['status'] == 'already' && pv[:rows][1]['status'] == 'already' &&
                                      pv[:rows][0]['already'].map(&:id) == [d1&.id]]
                chosen = imp.preview(project, data, user: actor, add_again: [2])
                checks << ['chosen', chosen[:rows][0]['status'] == 'again' && chosen[:rows][1]['status'] == 'already']
                refused = begin
                  imp.run!(project, again, user: actor)
                  false
                rescue imp::Refused
                  true
                end
                checks << ['skipped by default', refused && ::Document.count == docs_before + 2]
              end
            end
          end
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      rescue ::ActiveRecord::RecordInvalid, DocumentImport::Refused => err
        { 'ok' => false, 'want' => part, 'got' => "#{err.class}: #{err.message}" }
      end
      register_data_steps!
    end

    # What the steps could not say before, so that it is the scenario's data (made by Skapa and kept) and not only
    # checks that roll back.
    # Each finds what is there and makes the rest; texts come from the scenario's locale.
    def register_data_steps!
      # records_assessment_kinds: assessment kinds as data (AssessmentKinds), before the assessments. In scenario.yml
      # records: { assessment_kinds: [{ key: dual_use, scale: [unlikely, possible, likely], by: karin }] }; the names in the
      # locale at records.assessment_kinds.<key>.name and .scale.<value>, taken from every language the scenario has, and
      # an optional .reason for the settings' history. A key a plugin registered in code is the plugin's: noted and left.
      ::GkScenarios::Steps.register('records_assessment_kinds', plugin: :gk_records, order: 355) do |ctx|
        sc = ctx.scenario
        section(sc, :assessment_kinds).each do |k|
          key = k['key'].to_s
          if AssessmentKinds.coded?(key)
            ctx.remark("#{key}: registered by a plugin, left as it is")
            ctx.note(:rec_assessment_kind, key, Kinds.find(:assessment, key), false)
            next
          end
          names = texts_in_all(sc, :records, :assessment_kinds, key, :name)
          scale = Array(k['scale']).map { |v| { 'key' => v.to_s, 'names' => texts_in_all(sc, :records, :assessment_kinds, key, :scale, v.to_s) } }
          reason = sc.t?(:records, :assessment_kinds, key, :reason)&.to_s
          by = k['by'] ? ctx.get(:user, k['by']) : ::User.current
          changed = begin
            ctx.as(by) { AssessmentKinds.save!(key, names: names, scale: scale, reason: reason) }
          rescue ArgumentError => e
            raise ::GkScenarios::Error, e.message
          end
          ctx.note(:rec_assessment_kind, key, AssessmentKinds.find(key), changed)
        end
      end

      # records_verifications: verification statuses as data. records: { verifications: [{ key: v1, target: { issue: k },
      # status: hypothesis, by: johan, at: -3 }] } with the reason at records.verifications.<key>.reason (optional; the
      # instance's mode for records.verification decides whether it is kept). Hypotes, Delvis verifierad, Ej verifierad or
      # none, set as the person through Verification.change; Verifierad only through signoff's step reviews. A target is
      # any of the scenario's things ({ issue: }, { organization: }, { person: }, { assessment: }). When the scenario does
      # not name records: verification_trackers, the trackers of the issues named here are chosen for the row (the
      # setting verification_tracker_ids), since the row and the status are only there on a chosen tracker.
      ::GkScenarios::Steps.register('records_verifications', plugin: :gk_records, order: 360) do |ctx|
        sc = ctx.scenario
        rows = section(sc, :verifications)
        next if rows.empty?

        unless (sc.data['records'] || {}).key?('verification_trackers')
          ids = rows.filter_map { |v| (o = object(sc, v['target'])).is_a?(::Issue) ? o.tracker_id : nil }.uniq
          changed = ids.map { |id| Verification.choose_tracker!(id) }.any?
          ctx.note(:rec_verification_trackers, 'trackers', nil, changed) if ids.any?
        end
        cursor = {}
        rows.each do |v|
          obj = object(sc, v['target'])
          made, created = verify_as!(ctx, obj, v['status'], by: ctx.get(:user, v['by']), reason: sc.t?(:records, :verifications, v['key'], :reason)&.to_s,
                                                            label: v['key'], at: v['at'], cursor: cursor)
          ctx.note(:rec_verification, v['key'], made, created)
        end
      end

      # records_assessments: assessments as data, dated and kept whole as every assessment (Assessments.record). records:
      # { assessments: [{ key: a1, kind: dual_use, target: { organization: hemsjo }, by: johan, at: -6, outcome: possible,
      # verification: hypothesis }] }. outcome: a value on the kind's scale (its text in the scenario's language is kept
      # with the assessment), or for a kind without a scale the text records.assessments.<key>.outcome. In the locale under
      # records.assessments.<key>: basis (optional), values (optional, { <value key>: { label:, value: } } in order) and
      # verification_reason (optional). The heading is the kind's name in every language the kind has. verification: a
      # status of the assessment's own, set as verification_by (default by) as records_verifications does. Found again by
      # its source (the scenario and the key); a target { assessment: key } names it in other steps and expectations.
      ::GkScenarios::Steps.register('records_assessments', plugin: :gk_records, order: 365) do |ctx|
        sc = ctx.scenario
        cursor = {}
        section(sc, :assessments).each do |a|
          kind = Kinds.find(:assessment, a['kind']) or raise ::GkScenarios::Error, "#{a['key']}: no assessment kind #{a['kind']}"
          obj = object(sc, a['target'])
          type, id = ref(sc, a['target'])
          by = ctx.get(:user, a['by'])
          made = ::GkRecordsAssessment.for_target(type, id).where(kind: kind.key, origin_source_id: assessment_source(sc, a['key'])).order(:id).last
          created = made.nil?
          unless made
            outcome = nil
            if a.key?('outcome')
              outcome = kind.scale.present? ? kind.scale_label(a['outcome'], sc.locale) : sc.t(:records, :assessments, a['key'], :outcome)
              raise ::GkScenarios::Error, "#{a['key']}: #{a['outcome']} is not on the scale of #{kind.key}" if outcome.nil?
            end
            vals = sc.t?(:records, :assessments, a['key'], :values)
            values = (vals.is_a?(Hash) ? vals : {}).map { |k, h| { key: k.to_s, label: h.is_a?(Hash) ? h['label'].to_s : k.to_s, value: h.is_a?(Hash) ? h['value'].to_s : h.to_s } }
            names = kind.names.presence
            made = ctx.as(by) do
              Assessments.record(obj, kind.key, values: values, outcome: outcome, title: names ? Kinds.name_in(names, sc.locale) : nil,
                                                title_translations: names, basis: sc.t?(:records, :assessments, a['key'], :basis)&.to_s,
                                                user: by, origin: 'human', source: assessment_source(sc, a['key']),
                                                at: ctx.day(a['at'] || 0).in_time_zone + 11.hours)
            end
          end
          ctx.note(:rec_assessment, a['key'], made, created)
          next unless a['verification']

          ev, set = verify_as!(ctx, made, a['verification'], by: ctx.get(:user, a['verification_by'] || a['by']),
                                                             reason: sc.t?(:records, :assessments, a['key'], :verification_reason)&.to_s,
                                                             label: a['key'], at: a['at'], cursor: cursor)
          ctx.note(:rec_assessment_verification, a['key'], ev, set)
        end
      end

      # records_document_imports: Läs in dokument as data (DocumentImport, the same preview and run as the page). records:
      # { document_imports: [{ key: d1, project: framtid, by: karin, category: project_documents, files: [{ key: decision,
      # subproject: ap11, source: src_decision, edition: "1", date: "2026-06-12" }] }] }. The step builds the zip from the
      # locale (records.document_imports.<key>: source, the reading's source; list and zip, the file names, optional; files.
      # <file key>: file, title, from (optional) and body, a made-up text) with the list's columns in the instance's
      # language (fil, vad det är, varifrån, utgåva, datum, underprojekt, källa, kategori): underprojekt is the scenario
      # project's identifier, källa #<id> of the scenario's Källa issue, kategori the category named at
      # records.document_categories.<key>, made as a shared category when there is none by that name (the default when
      # there is no default). date: a date as text or { day: n }. A row with an error or a missing file stops the step;
      # files already there (the same SHA-256 in the same project) are found, the rest read in as the person. Kept: the
      # reading, the documents with their files, origin and event, and supported_by to the source.
      ::GkScenarios::Steps.register('records_document_imports', plugin: :gk_records, order: 370) do |ctx|
        sc = ctx.scenario
        section(sc, :document_imports).each do |d|
          require 'zip'
          require 'csv'
          base = [:records, :document_imports, d['key']]
          project = ctx.get(:project, d['project'])
          by = ctx.get(:user, d['by'])
          label = sc.t(*base, :source)
          category = nil
          if d['category']
            name = sc.t(:records, :document_categories, d['category'])
            category = ::DocumentCategory.shared.find_by(name: name) ||
                       ::DocumentCategory.create!(name: name, active: true, is_default: ::DocumentCategory.default.nil?)
          end
          files = {}
          list = ::CSV.generate(col_sep: ';') do |csv|
            csv << DocumentImport::FIELDS.map { |f| ::I18n.t("label_gk_records_docimp_field_#{f}") }
            Array(d['files']).each do |f|
              fname = sc.t(*base, :files, f['key'], :file)
              files[fname] = "#{sc.t(*base, :files, f['key'], :body).rstrip}\n".b
              date = f['date'].is_a?(Hash) && f['date'].key?('day') ? ctx.day(f['date']['day']).to_s : f['date'].to_s
              row = { 'file' => fname, 'title' => sc.t(*base, :files, f['key'], :title), 'source_text' => sc.t?(*base, :files, f['key'], :from).to_s,
                      'edition' => f['edition'].to_s, 'date' => date,
                      'subproject' => f['subproject'] ? ctx.get(:project, f['subproject']).identifier : '',
                      'source_issue' => f['source'] ? "##{ctx.get(:issue, f['source']).id}" : '', 'category' => category&.name.to_s }
              csv << DocumentImport::FIELDS.map { |x| row[x] }
            end
          end
          files = { (sc.t?(*base, :list) || 'dokumentlista.csv').to_s => "\xEF\xBB\xBF".b + list.b }.merge(files)
          data = ::Zip::OutputStream.write_buffer(::StringIO.new(+'')) do |zos|
            files.each { |n, bytes| zos.put_next_entry(n); zos.write(bytes) }
          end.string.b
          pv = ctx.as(by) { DocumentImport.preview(project, data, user: by) }
          bad = pv[:rows].reject { |r| DocumentImport.made?(r) || r['status'] == 'already' }
          raise ::GkScenarios::Error, "#{d['key']}: #{bad.map { |r| "#{r['file']} (#{r['status']}) #{Array(r['errors']).join(', ')}".strip }.join('; ')}" if bad.any?

          if pv[:rows].none? { |r| DocumentImport.made?(r) }
            ctx.note(:rec_document_import, d['key'], ::GkRecordsReading.where(target_type: DocumentImport::TARGET, source_label: label).order(:id).last, false)
            next
          end
          reading, = ctx.as(by) do
            att = DocumentImport.keep!(project, data, (sc.t?(*base, :zip) || "#{d['key']}.zip").to_s, by)
            DocumentImport.run!(project, att, user: by, source_label: label)
          end
          ctx.note(:rec_document_import, d['key'], reading, true)
        rescue DocumentImport::Refused => e
          raise ::GkScenarios::Error, "#{d['key']}: #{e.message}"
        end
      end

      # records_verification_status: the status one of the scenario's things has now, as data the steps made: {
      # records_verification_status: { issue: kp_power }, equals: hypothesis, by: johan }. equals: one of the four, or
      # none (no status said). by: the scenario's user who set it last (the row's set_by). Nothing is changed.
      ::GkScenarios::Expect.register('records_verification_status') do |ctx, e|
        obj = object(ctx.scenario, e['records_verification_status'])
        want = e['equals'].to_s.presence || 'none'
        got = Verification.get(obj) || 'none'
        checks = [[want, got == want]]
        checks << ['by', Verification.row(obj)&.set_by&.login == ::GkScenarios::Expect.login(ctx, e['by'])] if e['by']
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? got : "#{got}, not: #{failed.join(', ')}" }
      end

      # records_assessment_kind: an assessment kind the step made is there as data: { records_assessment_kind: dual_use,
      # scale: [unlikely, possible, likely] }: found among the kinds, its name in the scenario's language as the locale
      # says, and the scale's keys in that order (when scale is given)
      ::GkScenarios::Expect.register('records_assessment_kind') do |ctx, e|
        key = e['records_assessment_kind'].to_s
        kind = Kinds.find(:assessment, key)
        next({ 'ok' => false, 'want' => key, 'got' => 'no such kind' }) unless kind

        checks = [['data', kind.plugin == AssessmentKinds::PLUGIN]]
        checks << ['name', Kinds.name_in(kind.names, ctx.scenario.locale) == ctx.scenario.t(:records, :assessment_kinds, key, :name)]
        checks << ['scale', Array(kind.scale).map { |v| v['key'] } == Array(e['scale']).map(&:to_s)] if e.key?('scale')
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
      end

      # records_assessment: one assessment the step made, by its key: { records_assessment: a1, outcome: possible, by:
      # johan, verification: hypothesis }. Its kind as the scenario says, the outcome kept as the scale's text in the
      # scenario's language, made by the person, dated (at), kept whole (a change is refused) and, when given, its own
      # verification status now.
      ::GkScenarios::Expect.register('records_assessment') do |ctx, e|
        sc = ctx.scenario
        key = e['records_assessment'].to_s
        row = section(sc, :assessments).detect { |x| x['key'] == key }
        a = row && FINDERS['assessment'].call(sc, key)
        next({ 'ok' => false, 'want' => key, 'got' => row ? 'no assessment' : 'not in the scenario' }) unless a

        kind = Kinds.find(:assessment, a.kind)
        checks = [['kind', a.kind == row['kind'].to_s]]
        if e.key?('outcome')
          want = kind&.scale.present? ? kind.scale_label(e['outcome'], sc.locale) : sc.t(:records, :assessments, key, :outcome)
          checks << ['outcome', a.outcome == want]
        end
        checks << ['by', a.user&.login == ::GkScenarios::Expect.login(ctx, e['by'])] if e['by']
        checks << ['dated', a.assessed_at.to_date == ctx.day(row['at'] || 0)]
        fresh = ::GkRecordsAssessment.find(a.id)
        checks << ['kept whole', !fresh.update(outcome: "#{a.outcome} x") && ::GkRecordsAssessment.find(a.id).outcome == a.outcome]
        checks << ['verification', (Verification.get(a) || 'none') == e['verification'].to_s] if e['verification']
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
      end

      # records_document_import: what the step records_document_imports kept: { records_document_import: d1, documents:
      # 3, supported_by: 1 }. The reading by its source (route file, ZIP, one file with its SHA-256 and no attachment),
      # the documents its manifest names (how many; each in the project its row named and its fields pointing to the
      # reading), and how many of them have supported_by to a Källa issue.
      ::GkScenarios::Expect.register('records_document_import') do |ctx, e|
        sc = ctx.scenario
        key = e['records_document_import'].to_s
        row = section(sc, :document_imports).detect { |x| x['key'] == key }
        reading = row && ::GkRecordsReading.where(target_type: DocumentImport::TARGET, source_label: sc.t(:records, :document_imports, key, :source)).order(:id).first
        next({ 'ok' => false, 'want' => key, 'got' => row ? 'no reading' : 'not in the scenario' }) unless reading

        ids = Array(reading.manifest&.dig('rows')).filter_map { |f| f['document'] }
        docs = ::Document.where(id: ids).to_a
        checks = [['reading', reading.route == 'file' && reading.format == 'ZIP' && reading.files.size == 1 && reading.files.first['sha256'].to_s.match?(/\A\h{64}\z/) &&
                    ::Attachment.where(container_type: 'GkRecordsReading').none?]]
        checks << ["documents #{docs.size}", docs.size == e['documents'].to_i] if e.key?('documents')
        checks << ['origin', docs.all? { |d| Readings.origin(d, 'file')&.dig(:reading) == reading }]
        if e.key?('supported_by')
          n = docs.count { |d| ::GkRecordsLink.active.exists?(kind: DocumentImport::LINK, source_type: DocumentImport::TARGET, source_id: d.id, target_type: 'issue') }
          checks << ["supported_by #{n}", n == e['supported_by'].to_i]
        end
        failed = checks.reject { |_k, ok| ok }.map(&:first)
        { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
      end

      # records_identity: a thing's global identity (GkRecords::Identity). All in a transaction that is rolled back, so
      # nothing stays.
      # new_issue: two issues made like the scenario's issue in like: (copied, without attachments, subtasks, watchers
      # or link) by the scenario's user in as: each got its gid when it was made, a UUID version 7 (version nibble 7,
      # variant 10), the two differ and each stands once, the later is not earlier in time, Identity.find gives the
      # issue back, and origin and owner are the instance's id.
      #   change_owner: the owner of target: changed to a made-up instance id with a reason, as by:, writes the event
      #     owner_changed (the gid, the owner before and after, the person, the reason), the owner is the new one, the
      #     origin and the gid are as they were; the same owner again writes nothing; an origin already set cannot be
      #     changed and the row cannot be deleted.
      #   backfill: the identities of target_type: (default issue) are taken away inside the transaction; backfill! gives
      #     every thing of that sort one again (one each, UUID version 7, unique, origin the instance's id unless it was made
      #     from a dump), and a second run makes none and changes no gid.
      ::GkScenarios::Expect.register('records_identity') do |ctx, e|
        part = e['records_identity'].to_s
        next({ 'ok' => false, 'want' => 'new_issue | change_owner | backfill', 'got' => part }) unless %w[new_issue change_owner backfill].include?(part)
        next({ 'ok' => false, 'want' => 'the table gk_records_identities', 'got' => 'missing' }) unless Identity.ready?

        result = nil
        ::GkRecordsIdentity.transaction(requires_new: true) do
          checks = identity_checks(ctx, e, part)
          failed = checks.reject { |_k, ok| ok }.map(&:first)
          result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
          raise ::ActiveRecord::Rollback
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      end

      # records_system_text: a note the system writes with a key.
      #   readers: shown in Swedish to a Swedish reader and in English to an English reader, the key and values kept, the
      #     fallback body in the instance's language, a second note adds no revision, and a person's note (by:) is as she
      #     wrote it, without a key.
      #   changed: one locale's text changes (locale:, sv when not given; simulated with I18n's store_translations inside
      #     the check and put back after): exactly one revision row is added, for that locale only, and none again; the old
      #     note still shows the old text in that locale and the unchanged text in the others, with the text now beside
      #     it (also in REST); a new note shows the new text. Rows are never changed.
      # target: the thing the notes are written on (the scenario's first records note's target when not given). All in
      # a transaction that is rolled back.
      ::GkScenarios::Expect.register('records_system_text') do |ctx, e|
        part = e['records_system_text'].to_s
        next({ 'ok' => false, 'want' => 'readers | changed', 'got' => part }) unless %w[readers changed].include?(part)
        next({ 'ok' => false, 'want' => 'the table gk_records_text_revisions', 'got' => 'missing' }) unless SystemText.ready? && SystemText.columns?(::GkRecordsNote)

        result = nil
        texts = {}
        begin
          ::GkRecordsTextRevision.transaction(requires_new: true) do
            checks = system_text_checks(ctx, e, part, texts)
            failed = checks.reject { |_k, ok| ok }.map(&:first)
            result = { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
            raise ::ActiveRecord::Rollback
          end
        ensure
          # the locale text as it was, whatever happened in the check
          texts.each { |l, t| ::I18n.backend.store_translations(l.to_sym, { SYSTEM_TEXT_KEY => t }) if t }
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      end
    end
  end

  def self.register_scenarios! = Scenarios.register!
end
