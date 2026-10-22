# frozen_string_literal: true

module GkRecords
  # Skälfälten. One way for every place in the environment where a person is asked for a reason. A place declares itself
  # with its mode today as the default, so nothing changes until the administrator changes it:
  # GkRecords::Reasons.register('people.relation_end', plugin::gk_people, label::label_x, default::required) draws the
  # shared field (gk_records_reason_field, GkRecordsHelper) and lets the server decide: r =
  # GkRecords::Reasons.check('people.relation_end', params[:reason]) return fail(r.error) unless
  # r.ok...Events.write(..., reason: r.text) Modes: off (no field, no reason kept), optional, required (blank is
  # refused, with an optional least length).
  # Administration > Skäl sets a mode for the installation and per place (Enligt systeminställningen, Av, Valfritt, Krävs);
  # every change is an event. A fixed place keeps its own requirement and gets the help only. The help: the person's own
  # latest reason for the place as a greyed suggestion that counts only when chosen, earlier reasons to choose, and, on
  # the administrator's places only, the most common ones in the installation. A #123 in a reason becomes a link from
  # the reason to the issue (kind reason_cites).
  module Reasons
    MODES = %w[off optional required].freeze
    ALL = '*'          # the row for the installation
    PLACES = 'places'  # the installation's mode that lets every place keep its own default
    INHERIT = 'inherit'
    KIND = 'reason_mode_changed'
    LINK = 'reason_cites'
    TTL = 30

    Place = Struct.new(:key, :plugin, :label_key, :default, :admin, :min, :fixed, keyword_init: true) do
      def label = ::I18n.t(label_key, default: key)
      def plugin_name = Redmine::Plugin.registered_plugins[plugin.to_sym]&.name || plugin.to_s
    end

    Result = Struct.new(:ok, :text, :error, keyword_init: true)

    # The place a reason in this request was checked for, so Events.write can keep it with the event (the suggestions
    # are read from there); reset by Rails between requests
    class Current < ActiveSupport::CurrentAttributes
      attribute :key
    end

    module_function

    def all = (@all ||= {})

    def register(key, plugin:, label: nil, default: :optional, admin: false, min: nil, fixed: false)
      k = key.to_s
      d = default.to_s
      raise ArgumentError, "reason place #{k}: default #{d} is not one of #{MODES.join(', ')}" unless MODES.include?(d)

      all[k] = Place.new(key: k, plugin: plugin.to_s, label_key: label || :"label_gk_reason_#{k.tr('.', '_')}", default: d,
                         admin: admin ? true : false, min: min&.to_i, fixed: fixed ? true : false)
    end

    def find(key) = all[key.to_s]

    # The person's earlier reasons as suggestions only where a plugin gives a search field of the select2 kind and
    # says so here (records_1021-SID-30: "inget förslag annat än om select2-funktionalitet finns via annat plugin");
    # without it the field has no suggestion, no Använd for one and no list
    def suggest_with!(plugin) = (@suggest_by = plugin.to_s)
    def suggest? = !@suggest_by.nil?

    def stored
      if @stored.nil? || @loaded_at.nil? || Time.current - @loaded_at > TTL
        @stored = ::GkRecordsReasonMode.table_exists? ? ::GkRecordsReasonMode.pluck(:key, :mode).to_h : {}
        @loaded_at = Time.current
      end
      @stored
    rescue StandardError
      {}
    end

    def forget! = (@stored = nil)

    # Nothing chosen: off, so that a new installation is close to core and grows from there (the owner, human test
    # records_1021-SID-24); every place's own default is still there to choose (PLACES), and a fixed place keeps its own
    def installation_mode
      m = stored[ALL]
      return m if MODES.include?(m) || m == PLACES

      'off'
    end

    # The place's own row: a mode, or inherit (Enligt systeminställningen)
    def own_mode(key)
      m = stored[key.to_s]
      MODES.include?(m) ? m : INHERIT
    end

    # What holds now: a fixed place its own default; else the place's own mode, else the installation's, else the default.
    # A place nobody declared is optional (a forgotten declaration never refuses a save).
    def mode(key)
      p = find(key)
      return 'optional' unless p
      return p.default if p.fixed

      own = own_mode(p.key)
      return own unless own == INHERIT

      inst = installation_mode
      inst == PLACES ? p.default : inst
    end

    def off?(key) = mode(key) == 'off'
    def required?(key) = mode(key) == 'required'

    # The server decides. off: ok with no text, whatever was sent. optional: ok, the text if any. required: refused when
    # blank or shorter than the place's least length. A fixed place is checked by its owner, so here it is only noted.
    def check(key, value)
      text = value.to_s.strip.presence
      p = find(key)
      Current.key = p&.key
      return Result.new(ok: true, text: text) if p.nil? || p.fixed

      case mode(p.key)
      when 'off' then Result.new(ok: true, text: nil)
      when 'required'
        return Result.new(ok: false, error: ::I18n.t(:error_gk_records_reason_required)) if text.nil?
        return Result.new(ok: false, error: ::I18n.t(:error_gk_records_reason_short, count: p.min)) if p.min && text.length < p.min

        Result.new(ok: true, text: text)
      else Result.new(ok: true, text: text)
      end
    end

    # A reason the system gives, not a person, as a key (SystemText): yields the text in the instance's language, and
    # inside the block a reason that is exactly that text keeps the key and values, so it is shown in the reader's
    # language as it stood (Events.write, Notes.write, GkRecordsLink)
    def system(key, values = {}, &block) = SystemText.as_reason(key, values, &block)

    # The person's own reasons for the place, latest first, then (on the administrator's places only) the most common
    # ones others wrote; each once (any case). latest: the greyed suggestion.
    def suggestions(key, user = User.current, limit: 6)
      return { latest: nil, list: [] } unless user&.logged? && ::GkRecordsEvent.column_names.include?('reason_key')

      own = texts(::GkRecordsEvent.where(reason_key: key.to_s, user_id: user.id).order(id: :desc).limit(60))
      common = []
      if find(key)&.admin
        common = texts(::GkRecordsEvent.where(reason_key: key.to_s).where.not(user_id: user.id).order(id: :desc).limit(300))
                 .tally.sort_by { |_t, n| -n }.map(&:first)
      end
      seen = {}
      list = (own + common).select { |t| seen[t.downcase] ? false : (seen[t.downcase] = true) }.first(limit)
      { latest: own.first, list: list }
    rescue StandardError
      { latest: nil, list: [] }
    end

    def texts(scope) = scope.includes(:reason_note).map(&:reason_text).map(&:strip).reject(&:empty?)

    # The issues a reason mentions (#123), those that exist
    def issue_ids(text)
      ids = text.to_s.scan(/(?<![\w&])#(\d+)\b/).flatten.map(&:to_i).uniq.first(20)
      ids.empty? ? [] : ::Issue.where(id: ids).pluck(:id)
    end

    # After Events.write: a link from the reason (its note, or the thing when the reason sits in the event) to every
    # issue it mentions; a failed link never fails the event
    def link_issues(event, target_key, target_id, text, user)
      return unless Kinds.find(:link, LINK)

      from = event.reason_note_id ? ['gk_records_note', event.reason_note_id] : [target_key, target_id]
      issue_ids(text).each do |iid|
        next if from == ['issue', iid]

        ::GkRecordsLink.create(kind: LINK, source_type: from[0], source_id: from[1], target_type: 'issue', target_id: iid,
                            user_id: user&.id, origin: event.origin)
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_records] reason links not made for event #{event&.id}: #{e.message}")
    end

    # The administrator's change of a mode, for the installation (ALL) or a place; an event with the reason
    def set_mode!(key, value, reason: nil, user: User.current)
      k = key.to_s
      allowed = k == ALL ? MODES + [PLACES] : MODES + [INHERIT]
      raise ArgumentError, "reason mode #{value} for #{k}" unless allowed.include?(value.to_s)
      raise ArgumentError, "no reason place #{k}" unless k == ALL || (find(k) && !find(k).fixed)

      forget!
      before = k == ALL ? installation_mode : own_mode(k)
      before_now = k == ALL ? nil : mode(k)
      row = ::GkRecordsReasonMode.find_or_initialize_by(key: k)
      row.mode = value.to_s
      row.updated_by_id = user&.logged? ? user.id : nil
      row.save!
      forget!
      return row if before == row.mode

      details = { 'place' => k, 'mode' => [before, row.mode] }
      details['now'] = [before_now, mode(k)] if before_now
      record(row, details, reason, user)
      row
    end

    def record(row, details, reason, user)
      return unless Targets.find('reason_mode') && Kinds.find(:event, KIND)

      Events.write(row, KIND, details: details, reason: reason.presence, user: user&.logged? ? user : nil)
    end

    def by_plugin(fixed: false)
      all.values.select { |p| p.fixed == fixed }.group_by(&:plugin)
         .sort_by { |pl, _| Redmine::Plugin.registered_plugins[pl.to_sym]&.name.to_s }
    end

    def register_records!
      Targets.register('reason_mode', model: 'GkRecordsReasonMode',
                                      visible: ->(_m, user) { user.admin? }, editable: ->(_m, user) { user.admin? },
                                      label: ->(m) { "#{::I18n.t(:label_gk_records_reasons)}: #{m.place_label}" },
                                      url: ->(_m) { Rails.application.routes.url_helpers.gk_records_reasons_path })
      Kinds.register_event(KIND, plugin: :gk_records, label_key: 'label_gk_records_event_reason_mode_changed', target: 'reason_mode')
      Kinds.register_link(LINK, plugin: :gk_records, label_key: 'label_gk_records_link_reason_cites',
                                reverse_label_key: 'label_gk_records_link_reason_cited_by')
      register('records.reason_modes', plugin: :gk_records, label: :label_gk_reason_records_reason_modes, default: :optional, admin: true)
      register('records.settings', plugin: :gk_records, label: :label_gk_reason_records_settings, default: :optional, admin: true)
      register('records.link_manual', plugin: :gk_records, label: :label_gk_reason_records_link_manual, default: :required)
      register('records.note_void', plugin: :gk_records, label: :label_gk_reason_records_note_void, default: :required)
      # A verification status set by hand (Delvis verifierad, Ej verifierad, Hypotes, none)
      register('records.verification', plugin: :gk_records, label: :label_gk_reason_records_verification, default: :optional)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] reason places not registered: #{e.message}")
    end
  end
end

module GkRecords
  # The shared field's Använd and chips work on every page, also in a form fetched into a popup (a script inside a
  # fetched fragment never runs); the helper's own script is then a no-op (one listener per page)
  class ReasonHooks < Redmine::Hook::ViewListener
    def view_layouts_base_body_bottom(context = {})
      return '' unless User.current.logged?

      context[:hook_caller].respond_to?(:gk_records_reason_script) ? context[:hook_caller].gk_records_reason_script : ''
    end
  end
end
