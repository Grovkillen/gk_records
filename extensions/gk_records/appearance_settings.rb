# frozen_string_literal: true

module GkRecords
  # The shared register of the GK plugins' appearance settings: everything a GK plugin changes in how Redmine's pages
  # look or behave. Every plugin declares its settings here, each with its group on the page, its levels, its values and
  # GK's proposal, and asks before it loads or draws what the setting changes:
  #   GkRecords::AppearanceSettings.register('tags.sidebar', plugin: :gk_tags, group: :lists,
  #                                          label: :label_gk_tags_appearance_sidebar, help: :text_gk_tags_appearance_sidebar,
  #                                          values: { 'sidebar_limit' => { kind: :number, default: 15, min: 1, max: 1000 } })
  #   GkRecords::AppearanceSettings.on_for?('tags.sidebar', user)
  #   GkRecords::AppearanceSettings.value('tags.sidebar', 'sidebar_limit')
  # Levels: off is Redmine's own; optional is on with the administrator's values as the default, and each person may
  # switch it off or choose their own values; forced is the administrator's values for everyone. A setting that applies
  # to all or none has only off and forced. Every setting is off in a new installation; a key nobody declared is off,
  # and a plugin without records has every setting off. Every change by an administrator is an event on the setting with
  # the form's reason; a person's change is an event of its own kind, without a reason.
  # Shared values (register_shared) belong to no single setting: several settings read them, and they have no level.
  module AppearanceSettings
    GROUPS = %w[instance lists issue forms text calendar notices admin].freeze
    SHARED = 'shared'
    MODES = %w[off optional forced].freeze
    TWO_MODES = %w[off forced].freeze
    # a setting each person chooses, never forced for all
    PERSON_MODES = %w[off optional].freeze
    KINDS = %w[number flag text select choice table list action].freeze
    PERSON_CONTROLS = %w[switch segment select table].freeze
    TARGET = 'appearance_setting'
    KIND = 'appearance_setting_changed'
    PERSON_KIND = 'appearance_setting_chosen'
    # A person's "Like Redmine for me": every optional setting off for the person, the person's choices kept
    REDMINE = '*'
    TTL = 30 # seconds before another process's change is seen
    KEY = /\A[a-z0-9_]+\.[a-z0-9_.]+\z/

    # A setting's value is wrong (out of range, not one of the choices); the whole save is refused
    class Invalid < StandardError
      attr_reader :key, :name

      def initialize(key, name, message = nil)
        @key = key
        @name = name
        super(message || "#{key}: #{name}")
      end
    end

    # A save that leaves a setting with reason_when_sharp on and sharp was given no reason; nothing is saved
    class ReasonNeeded < Invalid; end

    # kind: number (min, max, step), flag, text (max: the length), select or choice (choices: values, [label, value]
    # pairs or a lambda giving either), table (choices: the partial that draws it; the value is a hash). person: the
    # person may choose this value when the setting is optional. help: a few words beside the field (a unit); info: a
    # quiet help text under the value, as core's forms write theirs. list and action: see appearance_kinds.rb.
    # A table may also say which texts in a cell count as empty (blank:, '' always; the same in every language and
    # whatever the page draws) and give the words of its cells (cells:, a lambda, see book).
    Value = Struct.new(:row, :name, :kind, :default, :min, :max, :step, :choices, :label_key, :help_key, :info_key, :person,
                       :pattern, :placeholder, :url, :confirm_key, :blank, :cells, keyword_init: true) do
      def label = ::I18n.t(label_key, default: name)
      def help = help_key && ::I18n.exists?(help_key) ? ::I18n.t(help_key) : ''
      def info = info_key && ::I18n.exists?(info_key) ? ::I18n.t(info_key) : ''
      def blanks = ([''] + Array(blank).map(&:to_s)).uniq

      def choice_list
        c = choices.respond_to?(:call) ? choices.call : choices
        Array(c)
      rescue StandardError
        []
      end

      def choice_values = choice_list.map { |c| c.is_a?(Array) ? c.last.to_s : c.to_s }
    end

    Row = Struct.new(:key, :plugin, :group, :label_key, :help_key, :modes, :default, :proposal, :values, :related, :requires,
                     :preview, :steps, :anonymous, :needs, :needs_plugin, :in_core, :core_link, :moved_from, :person, :person_off, :order,
                     :used_by, :person_default, :warning_key, :warning_sharp_key, :sharp_when, :reason_when_sharp,
                     :footprint, :applies, keyword_init: true) do
      def label = ::I18n.t(label_key, default: key)
      def help = help_key && ::I18n.exists?(help_key) ? ::I18n.t(help_key) : ''
      def plugin_name = Redmine::Plugin.registered_plugins[plugin.to_sym]&.name || Features.name_of(plugin)
      def shared? = group == SHARED
      def two_modes? = modes == TWO_MODES
      def value(name) = values[name.to_s]
    end

    module_function

    def declared = (@declared ||= {})

    # Registered again after a reload. group: one of GROUPS. modes: MODES, or TWO_MODES for a setting that applies to
    # all or none. default: the level of a new installation, off unless a decision says otherwise. proposal: the level
    # in GK's proposal. values: { name => { kind:, default:, min:, max:, step:, choices:, label:, help:, info:, person: } }.
    # related: keys shown as "Goes with"; requires: keys that must be on with it. preview: a partial that draws the
    # setting before and after; steps: three locale keys that say how it works where there is no picture. anonymous:
    # also for someone not logged in. needs: a lambda saying the setting's thing exists in the instance, needs_plugin:
    # the plugin named when it does not. in_core: a lambda saying Redmine already has it, core_link: a lambda giving
    # Redmine's own setting as [the words of its path, the path]. moved_from: :features for a setting that was a function
    # before. person: what a person's page draws when the setting is optional (switch, segment, select, table);
    # person_off: a segment or select starts with Off, the person's way back to Redmine's own. modes may also be
    # PERSON_MODES, for what each person chooses and nobody forces. person_default: 'off' makes an optional setting
    # start off for each person. warning, warning_sharp, sharp_when, reason_when_sharp: see appearance_kinds.rb.
    # footprint: where the setting changes something on the pages ({ anchors:, elements:, pages:, adds:, removes: }) and
    # applies: how the change gets there (class, server, script, data, or none for no visible effect); see footprint.rb.
    # A new setting with a visible effect declares its footprint; an anchor that breaks footprint.rb's rules is left out
    # and logged.
    def register(key, plugin:, group:, label: nil, help: nil, modes: MODES, default: 'off', proposal: 'off', values: {},
                 related: [], requires: [], preview: nil, steps: nil, anonymous: false, needs: nil, needs_plugin: nil,
                 in_core: nil, core_link: nil, moved_from: nil, person: :switch, person_off: false, order: 100,
                 person_default: 'on', warning: nil, warning_sharp: nil, sharp_when: nil, reason_when_sharp: false,
                 footprint: nil, applies: nil)
      return nil unless GkRecords.gui? # no setting without GK GUI Stuff (gate.rb)

      k = key.to_s
      raise ArgumentError, "appearance setting #{k}: the key is <plugin>.<name>" unless k.match?(KEY)
      raise ArgumentError, "appearance setting #{k} is a function in the register of functions" if Features.find(k)
      raise ArgumentError, "appearance setting #{k}: unknown group #{group}" unless GROUPS.include?(group.to_s)

      levels = Array(modes).map(&:to_s)
      raise ArgumentError, "appearance setting #{k}: levels #{levels.join(', ')}" unless [MODES, TWO_MODES, PERSON_MODES].include?(levels)
      raise ArgumentError, "appearance setting #{k}: default #{default}" unless levels.include?(default.to_s)
      raise ArgumentError, "appearance setting #{k}: proposal #{proposal}" unless levels.include?(proposal.to_s)
      raise ArgumentError, "appearance setting #{k}: person #{person}" unless PERSON_CONTROLS.include?(person.to_s)

      built = build_values(k, values)
      sharp = check_extras(k, built, person_default, sharp_when)
      fp = Footprint.normalize(footprint, k)
      how = Footprint.applies(applies, k)
      declared[k] = Row.new(key: k, plugin: plugin.to_s, group: group.to_s,
                            label_key: label || :"label_gk_appearance_#{k.tr('.', '_')}", help_key: help,
                            modes: levels.freeze, default: default.to_s, proposal: proposal.to_s,
                            values: built, related: Array(related).map(&:to_s), requires: Array(requires).map(&:to_s),
                            preview: preview, steps: steps, anonymous: anonymous ? true : false, needs: needs,
                            needs_plugin: needs_plugin&.to_s, in_core: in_core, core_link: core_link, moved_from: moved_from&.to_s,
                            person: person.to_s, person_off: person_off ? true : false, order: order, used_by: [],
                            person_default: person_default.to_s, warning_key: warning, warning_sharp_key: warning_sharp,
                            sharp_when: sharp, reason_when_sharp: reason_when_sharp ? true : false,
                            footprint: stable_footprint(k, fp), applies: how)
    end

    # The footprint with only the anchors that keep to the rules; the others are logged
    def stable_footprint(key, footprint)
      bad = Footprint.problems(footprint)
      bad.each { |a, why| Rails.logger.warn("[gk_records] #{key}: anchor #{a} left out of the footprint (#{why})") } if bad.any? && defined?(Rails.logger) && Rails.logger
      bad.any? ? Footprint.stable(footprint) : footprint
    end

    # What the setting affects: its own footprint; a shared value without one has the footprints of the settings that
    # read it, put together. nil when nothing is described.
    def footprint(key)
      row = find(key)
      return nil unless row
      return row.footprint if row.footprint || !row.shared?

      parts = row.used_by.filter_map { |k| find(k)&.footprint }
      return nil if parts.empty?

      Footprint::PARTS.each_with_object({}) do |p, h|
        list = parts.flat_map { |f| Array(f[p]) }.uniq
        h[p] = list.freeze if list.any?
      end.freeze
    end

    # Whether the row says what it affects (Påverkar): a footprint, or applies none
    def described?(key)
      row = find(key)
      return false unless row

      Footprint.described?(footprint(key)) || row.applies == ['none']
    end

    # A value several settings read, without a level of its own (the group Shared values on the page). used_by: the
    # settings that read it. footprint: and applies: as for a setting, for a value whose effect is not what the settings
    # in used_by change; without them the value has the footprints of those settings.
    def register_shared(key, plugin:, values:, label: nil, help: nil, used_by: [], order: 100, footprint: nil, applies: nil)
      k = key.to_s
      raise ArgumentError, "shared value #{k}: the key is <plugin>.<name>" unless k.match?(KEY)
      raise ArgumentError, "shared value #{k} is a function in the register of functions" if Features.find(k)

      fp = Footprint.normalize(footprint, k)
      how = Footprint.applies(applies, k)
      declared[k] = Row.new(key: k, plugin: plugin.to_s, group: SHARED, label_key: label || :"label_gk_appearance_#{k.tr('.', '_')}",
                            help_key: help, modes: [].freeze, default: nil, proposal: nil, values: build_values(k, values),
                            related: [], requires: [], anonymous: true, person: 'switch', order: order,
                            used_by: Array(used_by).map(&:to_s), person_default: 'on', warning_key: nil,
                            warning_sharp_key: nil, sharp_when: nil, reason_when_sharp: false,
                            footprint: stable_footprint(k, fp), applies: how)
    end

    def build_values(key, values)
      (values || {}).to_h do |name, o|
        o = (o || {}).transform_keys(&:to_sym)
        kind = (o[:kind] || :number).to_s
        raise ArgumentError, "appearance setting #{key}: value #{name} has the unknown kind #{kind}" unless KINDS.include?(kind)

        raise ArgumentError, "appearance setting #{key}: action #{name} needs url:" if kind == 'action' && o[:url].nil?

        default = o.key?(:default) ? o[:default] : { 'flag' => false, 'table' => {}, 'text' => '', 'list' => [].freeze }[kind]
        default = nil if kind == 'action'
        [name.to_s, Value.new(row: key, name: name.to_s, kind: kind, default: default, min: o[:min], max: o[:max], step: o[:step],
                              choices: o[:choices], label_key: o[:label] || :"label_gk_appearance_#{key.tr('.', '_')}_#{name}",
                              help_key: o[:help], info_key: o[:info], person: o[:person] ? true : false,
                              pattern: o[:pattern], placeholder: o[:placeholder], url: o[:url]&.to_sym, confirm_key: o[:confirm],
                              blank: kind == 'table' ? Array(o[:blank]).map(&:to_s).freeze : nil,
                              cells: kind == 'table' && o[:cells].respond_to?(:call) ? o[:cells] : nil)]
      end.freeze
    end

    def find(key) = declared[key.to_s]
    def rows = declared.values.reject(&:shared?)
    def shared = declared.values.select(&:shared?)

    # The settings by group in the page's order, then the shared values: [[group, [rows]]]
    def by_group
      sort = ->(list) { list.sort_by { |r| [r.order, r.label.to_s.downcase] } }
      out = GROUPS.filter_map { |g| (list = rows.select { |r| r.group == g }).any? ? [g, sort.call(list)] : nil }
      out << [SHARED, sort.call(shared)] if shared.any?
      out
    end

    # Whether what the setting changes exists here (needs), and Redmine does not have it already (in_core)
    def present?(row) = call_quietly(row.needs, true)
    def in_core?(row) = call_quietly(row.in_core, false)
    def available?(row) = present?(row) && !in_core?(row)

    def call_quietly(fn, fallback)
      return fallback if fn.nil?

      fn.call ? true : false
    rescue StandardError => e
      Rails.logger.warn("[gk_records] appearance setting check failed: #{e.class} #{e.message}")
      fallback
    end

    # The instance's rows, kept TTL seconds: { key => { 'mode' => mode, 'values' => {} } }. The memory is shared by the
    # threads of the process. Inside a transaction the table answers and the memory is left alone: another thread's read
    # cannot stand in for what this one has written, and what may be rolled back stays here.
    def stored
      return read_rows(::GkRecordsAppearanceSetting.instance) if in_transaction?

      if @stored.nil? || @loaded_at.nil? || Time.current - @loaded_at > TTL
        @stored = read_rows(::GkRecordsAppearanceSetting.instance)
        @loaded_at = Time.current
      end
      @stored
    rescue StandardError
      {}
    end

    # A person's rows, kept TTL seconds per person, as stored above
    def person_stored(user)
      return {} unless user&.logged?
      return read_rows(::GkRecordsAppearanceSetting.where(user_id: user.id)) if in_transaction?

      @people ||= {}
      @people.clear if @people.size > 500
      at, data = @people[user.id]
      return data if at && Time.current - at <= TTL

      data = read_rows(::GkRecordsAppearanceSetting.where(user_id: user.id))
      @people[user.id] = [Time.current, data]
      data
    rescue StandardError
      {}
    end

    def in_transaction? = ::GkRecordsAppearanceSetting.connection.open_transactions.positive?

    def read_rows(scope)
      return {} unless ::GkRecordsAppearanceSetting.table_exists?

      scope.pluck(:key, :mode, :values_json).to_h { |k, m, v| [k, { 'mode' => m, 'values' => parse(v) }] }
    end

    def parse(json)
      v = json.present? ? JSON.parse(json) : {}
      v.is_a?(Hash) ? v : {}
    rescue JSON::ParserError
      {}
    end

    # A save in this process is seen here at once
    def forget!(user = nil)
      @stored = nil
      @books = nil
      user ? @people&.delete(user.id) : @people = nil
    end

    # The administrator's level, else the registration's default; off for a key nobody declared. A setting with two
    # levels never answers optional.
    def mode(key)
      row = find(key)
      return 'off' unless row && !row.shared?

      m = stored.dig(row.key, 'mode').to_s
      row.modes.include?(m) ? m : row.default
    end

    def on?(key) = mode(key) != 'off'

    # The administrator's value, else the value's default; nil for an action, which keeps no value
    def value(key, name)
      row = find(key)
      v = row&.value(name)
      return nil if v.nil? || v.kind == 'action'

      raw = stored.dig(row.key, 'values', v.name)
      c = raw.nil? ? nil : coerce(v, raw)
      c.nil? ? v.default : c
    end

    # Whether the setting is on for the person: off when nobody declared it, its thing is not there or Redmine has it;
    # someone not logged in gets the anonymous settings that are not off; forced is on; optional is on unless the
    # person switched it off or chose Like Redmine for me; with person_default off it is on only when the person chose it
    def on_for?(key, user = User.current)
      row = find(key)
      return false unless row && !row.shared? && available?(row)

      m = mode(row.key)
      return false if m == 'off'
      return row.anonymous if user.nil? || !user.logged?
      return true if m == 'forced'

      return false if redmine_for?(user)

      pm = person_stored(user).dig(row.key, 'mode')
      row.person_default == 'off' ? pm == 'on' : pm != 'off'
    end

    # The person's own value of an optional setting, else the administrator's
    def person_value(key, name, user = User.current)
      row = find(key)
      v = row&.value(name)
      return value(key, name) unless v&.person && user&.logged? && mode(key) == 'optional' && !redmine_for?(user)

      raw = person_stored(user).dig(row.key, 'values', v.name)
      c = raw.nil? ? nil : coerce(v, raw)
      c.nil? ? value(key, name) : c
    end

    # What the person chose about one setting: { on: true|false|nil, values: {}, default: true|false } (nil: follows the
    # default, which is the registration's person_default)
    def person_choice(key, user)
      h = person_stored(user)[key.to_s] || {}
      { on: { 'on' => true, 'off' => false }[h['mode'].to_s], values: h['values'] || {},
        default: find(key)&.person_default != 'off' }
    end

    # The grant that lets a person choose Like Redmine for me, given by the plugin that draws the person's page;
    # granted when nobody gave one
    def grant_redmine(callable) = (@grant = callable)
    def redmine_granted? = @grant.nil? || call_quietly(@grant, true)
    def redmine_chosen?(user) = person_stored(user).dig(REDMINE, 'mode') == 'on'
    def redmine_for?(user) = user&.logged? && redmine_granted? && redmine_chosen?(user) ? true : false

    # The settings that are optional now and there, for the person's page
    def optional = rows.select { |r| available?(r) && mode(r.key) == 'optional' }

    # The target levels of a fill button: :redmine every setting off, :proposal every setting at GK's proposal
    def fill(kind) = rows.to_h { |r| [r.key, kind.to_s == 'proposal' ? r.proposal : 'off'] }

    # The installation's start choice (the profile's appearance), carried out once when the instance
    # is made: the fill of the choice for the settings that can be chosen here, each changed level an event, and always
    # one event for the instance on the row START (a key no setting can have) with the choice, also when no level
    # changed; every event with the system's reason "installation". Returns the changed keys, nil when the instance
    # already has rows.
    # While the gate to GK GUI Stuff is closed the choice waits: no setting is known then, so a choice kept then would
    # count as made without one level set. Nothing is saved and no event is written (nil, and a line in the log); the
    # choice is made when the gate is open.
    START = 'start'
    START_CHOICES = { 'as_redmine' => :redmine, 'gk_proposal' => :proposal }.freeze
    START_REASON = :text_gk_records_reason_installation

    def start!(choice)
      c = choice.to_s
      raise ArgumentError, "appearance settings: unknown start choice #{c}" unless START_CHOICES.key?(c)

      if (closed = GkRecords.gui_closed)
        Rails.logger.warn("[gk_records] appearance start choice #{c} waits: GK GUI Stuff is #{closed}")
        return nil
      end
      return nil if ::GkRecordsAppearanceSetting.instance.exists?

      changed = []
      SystemText.as_reason(START_REASON) do |text|
        ::GkRecordsAppearanceSetting.transaction do
          modes = fill(START_CHOICES[c]).each_with_object({}) do |(key, m), out|
            row = find(key)
            out[row.key] = m if row && !row.shared? && available?(row) && m != mode(row.key)
          end
          changed = save!(modes: modes, reason: text, user: nil) if modes.any?
          rec = ::GkRecordsAppearanceSetting.new(key: START, user_id: ::GkRecordsAppearanceSetting::INSTANCE)
          rec.values_hash = { 'choice' => c }
          rec.save!
          # never quietly without its trace: a failure here undoes the whole start choice
          Events.write(rec, KIND, details: { 'appearance_start' => [nil, c] }, reason: text, user: nil)
        end
      end
      forget!
      changed
    end

    # A value as it is kept, or nil when it is not a valid value of its kind
    def coerce(v, raw)
      case v.kind
      when 'number'
        s = raw.to_s.strip
        return nil unless s.match?(/\A-?\d+\z/)

        n = s.to_i
        return nil if (v.min && n < v.min) || (v.max && n > v.max)
        # off the step counted from min, as the browser's field counts it
        return nil if v.step && ((n - (v.min || 0)) % v.step).nonzero?

        n
      when 'flag'
        return true if [true, 1, '1', 'true', 'on'].include?(raw)

        [false, 0, '0', 'false', 'off', ''].include?(raw) ? false : nil
      when 'text' then raw.is_a?(String) ? raw.strip.first(v.max || 2000) : nil
      when 'select', 'choice' then v.choice_values.include?(raw.to_s) ? raw.to_s : nil
      when 'table'
        h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        h.is_a?(Hash) ? table_compact(v, h) : nil
      when 'list' then coerce_list(v, raw)
      when 'action' then nil
      end
    end

    # A table without its empty cells, at every depth: nothing, an empty table and a text the value counts as empty
    # (blank:) are the same as a cell that is not there, on the instance's row and on a person's; a text is kept without
    # the spaces around it, as a text value is, so that "abc " holds what "abc" holds (the box of Spara trims alike)
    def table_compact(v, h)
      h = h.to_unsafe_h if h.respond_to?(:to_unsafe_h)
      return {} unless h.is_a?(Hash)

      blanks = v.respond_to?(:blanks) ? v.blanks : ['']
      h.each_with_object({}) do |(k, x), out|
        x = x.to_unsafe_h if x.respond_to?(:to_unsafe_h)
        x = table_compact(v, x) if x.is_a?(Hash)
        x = x.strip if x.is_a?(String)
        next if x.nil? || x == {} || (x.is_a?(String) && blanks.include?(x))

        out[k.to_s] = x
      end
    end

    # Whether two values hold the same; for a table, the same cells once the empty ones are left out
    def same_value?(v, a, b)
      table = v&.kind == 'table' || a.is_a?(Hash) || b.is_a?(Hash)
      table ? table_compact(v, a) == table_compact(v, b) : a == b
    end

    # The words of a table's cells, from the plugin that owns the page (the registration's cells:, a lambda taking
    # person: for the words of a person's row), kept TTL seconds per language and row: { cell => entry }, an entry
    # { label:, words: { value => word }, empty:, text:, parts: { inner key => entry } }. label: the cell's name on the
    # page ('' adds no step to the row's label); words: the value's word (a value not among them no longer exists);
    # empty: the page's word for the empty choice; text: the value is said as it is; parts: the cells inside it. records
    # knows nothing of what the cells are. nil without cells:, or when the lambda fails (logged): then the cells are
    # named by their keys, nothing is called gone and nothing is kept.
    def book(v, person: false)
      fn = v.respond_to?(:cells) ? v.cells : nil
      return nil unless fn.respond_to?(:call)

      key = [v.row, v.name, ::I18n.locale.to_s, person ? 1 : 0]
      @books ||= {}
      at, kept = @books[key]
      return kept if at && Time.current - at <= TTL

      b = fn.parameters.any? { |_, n| n == :person } ? fn.call(person: person) : fn.call
      return nil unless b.is_a?(Hash)

      b = b.transform_keys(&:to_s)
      @books.clear if @books.size > 200
      @books[key] = [Time.current, b]
      b
    rescue StandardError => e
      Rails.logger.warn("[gk_records] the words of #{v.row} #{v.name} not read: #{e.class} #{e.message}")
      nil
    end

    # The cells the page does not know kept from before: with the owner's book, a cell it has no entry for (a button or
    # a tracker that is gone) is never cleared by a save that did not concern it
    def keep_gone(v, before, after, person: false)
      b = before.is_a?(Hash) && after.is_a?(Hash) ? book(v, person: person) : nil
      return after unless b

      kept = table_compact(v, before).reject { |k, _| b.key?(k) }
      kept.any? ? table_compact(v, kept.merge(after)) : after
    end

    # A value that no longer exists: the stored value followed by "(no longer exists)"
    def gone_word(x) = ::I18n.t(:text_gk_records_appearance_gone, value: x.to_s)

    # The neutral word for an empty cell (tomt, empty): owned here and used by the plugin that owns the page where its
    # page has no word of its own, so that the box of Spara and the event log say it alike
    def empty_word = ::I18n.t(:label_gk_records_appearance_empty)

    # How far back the newest change is looked for behind an event that changed nothing: this many older events of that
    # one setting, counted for each such setting on its own
    LOOK_BACK = 500

    # The newest event of each setting that changed something: { key => { event:, user:, at:, reason:, mode: } }. An
    # event whose rows are all empty (written before a save with nothing changed was left out; the event log says
    # Inget ändrades for it) is passed over, and the one before it that changed something stands instead. One query
    # for the rows and one for the events, never one per setting; only a setting whose newest event changed nothing
    # asks one more, and those found are read in one
    def last_changes(keys = nil)
      return {} unless defined?(::GkRecordsEvent) && ::GkRecordsAppearanceSetting.table_exists?

      scope = ::GkRecordsAppearanceSetting.instance
      scope = scope.where(key: Array(keys).map(&:to_s)) if keys
      ids = scope.pluck(:id, :key).to_h
      return {} if ids.empty?

      base = ::GkRecordsEvent.where(target_type: TARGET, kind: KIND, target_id: ids.keys)
      events = ::GkRecordsEvent.where(id: base.group(:target_id).select('MAX(id)')).includes(:user, :reason_note).to_a
      events = newest_events(events) do |idle|
        found = older_change_ids(base, idle)
        found.any? ? ::GkRecordsEvent.where(id: found).includes(:user, :reason_note).to_a : []
      end
      events.each_with_object({}) do |e, h|
        h[ids[e.target_id]] = { event: e, user: e.user, at: e.created_at, reason: e.reason_text.to_s.squish,
                                mode: Array(e.details_hash['mode']).last }
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_records] appearance settings' last changes not read: #{e.message}")
      {}
    end

    # The newest events that changed something, from each setting's newest event: those that did stand, those that did
    # not are given to the block, which answers the events that stand for them instead (none for a setting where it
    # found none)
    def newest_events(events)
      idle, kept = events.partition { |e| !changed_something?(e.details_hash) }
      idle.empty? ? kept : kept + Array(yield(idle))
    end

    # The id of the newest older event that changed something, for each event that changed nothing, from base (the
    # events of the settings): each setting is looked back in on its own, so that a setting with many empty events never
    # hides another's change
    def older_change_ids(base, idle)
      idle.filter_map do |e|
        list = base.where(target_id: e.target_id).where('id < ?', e.id).order(id: :desc).limit(LOOK_BACK).pluck(:id, :target_id, :details)
        newest_changes(list).first
      end
    end

    # The id of each setting's newest event that changed something, from [id, target id, details as JSON] newest first
    def newest_changes(list)
      list.each_with_object({}) do |(id, target, json), out|
        next if out.key?(target)

        d = begin
          JSON.parse(json.presence || '{}')
        rescue JSON::ParserError
          {}
        end
        out[target] = id if changed_something?(d)
      end.values
    end

    # Whether an event changed something: the start choice, a level, a value with a row of its own (a table's cell that
    # differs once empty and missing cells count alike, a list's entries, any other value that is not empty on both
    # sides) or a field of its own; the closed gate's mark alone is no change. The same rule as event_rows, which says
    # Inget ändrades for an event that changed nothing
    def changed_something?(details)
      d = details.is_a?(Hash) ? details.transform_keys(&:to_s) : {}
      return true if d.key?('appearance_start')
      return true if d['mode'].is_a?(Array) && d['mode'].size == 2

      key = d['appearance_setting'].to_s
      row = find(key)
      name = setting_name(key, row)
      values = d['values'].is_a?(Hash) ? d['values'] : {}
      return true if values.any? { |n, change| value_rows(row, name, n.to_s, change).any? }

      d.except('appearance_setting', 'appearance_start', 'mode', 'values').any? { |f, c| !(defined?(Gate) && Gate.detail?(f, c)) }
    end

    # The administrator's form: levels { key => mode } and values { key => { name => value } } (shared values too), with
    # the form's one reason, in one transaction. Only what differs from what holds is written, one event per changed
    # setting. A level the setting does not have, or a wrong value, raises Invalid and nothing is saved. Returns the
    # changed keys.
    def save!(modes: {}, values: {}, reason: nil, user: User.current, reason_key: nil)
      plain = ->(h) { (h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : (h || {}).to_h).transform_keys(&:to_s) }
      modes = plain.call(modes)
      values = plain.call(values)
      changed = []
      forget!
      ::GkRecordsAppearanceSetting.transaction do
        (modes.keys | values.keys).each do |key|
          row = find(key)
          next unless row

          new_mode = nil
          if modes.key?(key) && !row.shared?
            new_mode = modes[key].to_s
            raise Invalid.new(key, 'mode', "#{key}: no level #{new_mode}") unless row.modes.include?(new_mode)
          end
          new_values = checked_values(row, values[key]).to_h do |n, x|
            v = row.value(n)
            [n, v.kind == 'table' ? keep_gone(v, value(row.key, n), x) : x]
          end
          check_sharp_reason!(row, new_mode, new_values, reason)
          changed << key if write_instance(row, new_mode, new_values, reason, user, reason_key)
        end
      end
      forget!
      changed
    end

    def checked_values(row, given)
      given = given.respond_to?(:to_unsafe_h) ? given.to_unsafe_h : given
      return {} unless given.is_a?(Hash)

      given.each_with_object({}) do |(name, raw), out|
        v = row.value(name)
        next if v.nil? || v.kind == 'action'

        c = coerce(v, raw)
        raise Invalid.new(row.key, v.name) if c.nil?

        out[v.name] = c
      end
    end

    def write_instance(row, new_mode, new_values, reason, user, reason_key)
      rec = ::GkRecordsAppearanceSetting.find_or_initialize_by(key: row.key, user_id: ::GkRecordsAppearanceSetting::INSTANCE)
      before_mode = row.shared? ? nil : mode(row.key)
      before_values = row.values.keys.to_h { |n| [n, value(row.key, n)] }
      mode_change = new_mode && new_mode != before_mode ? [before_mode, new_mode] : nil
      value_changes = new_values.reject { |n, x| same_value?(row.value(n), before_values[n], x) }.to_h { |n, x| [n, [before_values[n], x]] }
      return false if mode_change.nil? && value_changes.empty?

      rec.mode = new_mode if mode_change
      rec.values_hash = rec.values_hash.merge(value_changes.transform_values(&:last)) if value_changes.any?
      rec.updated_by_id = user&.logged? ? user.id : nil
      rec.save!
      details = { 'appearance_setting' => row.key }
      details['mode'] = mode_change if mode_change
      details['values'] = value_changes if value_changes.any?
      record(rec, KIND, details, reason, reason_key)
      true
    end

    # A person's own choice about an optional setting, saved at once and without a reason: on (true, false, or nil to
    # follow the default) and the person's values; an event on the person's row. The key REDMINE is Like Redmine for me.
    def set_person!(user, key, on: nil, values: nil)
      raise ArgumentError, 'appearance settings: a person is needed' unless user&.logged?

      k = key.to_s
      return set_redmine_for!(user, on) if k == REDMINE

      row = find(k)
      raise ArgumentError, "appearance setting #{k} is not optional now" unless row && mode(k) == 'optional'

      given = checked_values(row, values).select { |n, _| row.value(n).person }
      rec = ::GkRecordsAppearanceSetting.find_or_initialize_by(key: k, user_id: user.id)
      before = { 'mode' => rec.mode, 'values' => rec.values_hash }
      given = given.to_h do |n, x|
        v = row.value(n)
        [n, v.kind == 'table' ? keep_gone(v, before['values'][n], x, person: true) : x]
      end
      rec.mode = on.nil? ? nil : (on ? 'on' : 'off') unless on.nil? && values
      rec.values_hash = before['values'].merge(given)
      write_person(user, rec, k, before)
    end

    def set_redmine_for!(user, on)
      rec = ::GkRecordsAppearanceSetting.find_or_initialize_by(key: REDMINE, user_id: user.id)
      before = { 'mode' => rec.mode, 'values' => rec.values_hash }
      rec.mode = on ? 'on' : 'off'
      write_person(user, rec, REDMINE, before)
    end

    # Only what changed is an event: a table is compared without its empty cells, so a save that leaves every cell as it
    # stood, or only sends empty ones, writes nothing
    def write_person(user, rec, key, before)
      row = find(key)
      details = { 'appearance_setting' => key }
      details['mode'] = [before['mode'], rec.mode] if before['mode'] != rec.mode
      changes = rec.values_hash.reject { |n, x| same_value?(row&.value(n), before['values'][n], x) }
      details['values'] = changes.to_h { |n, x| [n, [before['values'][n], x]] } if changes.any?
      return rec if details.size == 1

      rec.updated_by_id = User.current.logged? ? User.current.id : user.id
      rec.save!
      forget!(user)
      record(rec, PERSON_KIND, details, nil, nil)
      rec
    end

    def record(rec, kind, details, reason, reason_key, user = User.current)
      return unless Targets.find(TARGET) && Kinds.find(:event, kind)

      Events.write(rec, kind, details: details, reason: reason.presence, reason_key: reason.present? ? reason_key : nil,
                              user: user&.logged? ? user : nil)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] appearance setting change not recorded for #{rec.key}: #{e.message}")
    end

    # An event on a setting's row in words, for the event log, its CSV and its search (register_event rows:): one row
    # per level and per value that changed, labelled as the box of Spara on GK GUI Stuff's form page labels them, the
    # setting's name for its level and "<setting> · <value>" for a value, before and after in the words the pages show
    # (Av, Valfritt, Tvingat; a choice's own word; Ja or Nej). The setting's key is no row of its own: every row names
    # the setting. A value nobody declares any more is named by its name, its values as text; nothing is ever shown as
    # JSON. person: the words of a person's own choice (På, Av, Följer förvalet). A table's row where both sides are empty
    # is left out, also in an event written before empty and missing cells were counted alike (events are never
    # rewritten); an event with nothing left says so in one row (Inget ändrades), before the gate's row. Plain texts only.
    def event_rows(details, person: false)
      d = details.is_a?(Hash) ? details.transform_keys(&:to_s) : {}
      key = d['appearance_setting'].to_s
      row = find(key)
      name = setting_name(key, row)
      out = []
      out << { label: ::I18n.t(:label_gk_records_appearance_start), to: start_word(Array(d['appearance_start']).last) } if d.key?('appearance_start')
      m = d['mode']
      out << { label: name, from: level_word(m[0], person), to: level_word(m[1], person) } if m.is_a?(Array) && m.size == 2
      (d['values'].is_a?(Hash) ? d['values'] : {}).each { |n, change| out.concat(value_rows(row, name, n.to_s, change, person: person)) }
      out << { label: name, value: ::I18n.t(:text_gk_records_appearance_nothing_changed) } if out.empty?
      d.except('appearance_setting', 'appearance_start', 'mode', 'values').each do |f, c|
        out << if defined?(Gate) && Gate.detail?(f, c) then { label: Gate.label, value: Gate.word(c) }
               elsif c.is_a?(Array) && c.size == 2 then { label: f, from: plain_word(c[0]), to: plain_word(c[1]) }
               else { label: f, value: plain_word(c) }
               end
      end
      out
    end

    # The setting's name as the page shows it; Som Redmine för mig for a person's REDMINE; the key when nobody declares it
    def setting_name(key, row = find(key))
      return row.label.to_s if row
      return ::I18n.t(:label_gk_records_appearance_redmine_for_me) if key == REDMINE

      key.to_s
    end

    # A level in words: Av, Valfritt, Tvingat for the instance; På, Av or Följer förvalet (nil) for a person
    def level_word(mode, person = false)
      k = if person then { 'on' => :on, 'off' => :off, '' => :default }[mode.to_s]
          elsif MODES.include?(mode.to_s) then mode.to_s
          end
      return mode.to_s.presence || ::I18n.t(:label_none) unless k

      ::I18n.t(person ? :"label_gk_records_appearance_person_#{k}" : :"label_gk_records_appearance_level_#{k}")
    end

    # The start choice in words (Som Redmine, GK:s förslag)
    def start_word(choice)
      c = choice.to_s
      START_CHOICES.key?(c) ? ::I18n.t(:"label_gk_records_appearance_start_#{c}") : (c.presence || ::I18n.t(:label_none))
    end

    # The rows of one value's change: a table one row per cell that changed (table_rows), a list the entries taken out
    # (−) and those put in (+), the sign saying which (signed), any other its value before and after in words
    def value_rows(row, name, n, change, person: false)
      v = row&.value(n)
      word = v ? v.label.to_s : n
      label = ::I18n.t(:text_gk_records_appearance_value_label, name: name, value: word)
      return [{ label: label, value: plain_word(change) }] unless change.is_a?(Array) && change.size == 2

      before, after = change
      if before.is_a?(Hash) || after.is_a?(Hash) || v&.kind == 'table'
        return table_rows(v, label, word, before, after, person)
      elsif before.is_a?(Array) || after.is_a?(Array)
        b = Array(before).map(&:to_s)
        a = Array(after).map(&:to_s)
        gone = (b - a).map { |x| "#{MINUS} #{x}" }
        come = (a - b).map { |x| "+ #{x}" }
        return [{ label: label, from: gone.join(', ').presence, to: come.join(', ').presence, signed: true }] if gone.any? || come.any?
      end
      # nothing on both sides (an event written before empty values were counted alike) is no row
      return [] if blank_word?(before) && blank_word?(after)

      [{ label: label, from: value_word(v, before), to: value_word(v, after) }]
    end

    # Whether a value holds nothing: nil, a text of spaces, an empty list or table
    def blank_word?(x) = x.nil? || x.to_s.strip.empty? || (x.respond_to?(:empty?) && x.empty?)

    MINUS = "−"

    # A table's rows: one per cell that differs once the empty cells are left out, an inner table's cells each a row of
    # their own ("<setting> · <value> › <cell> › <part>"); none when no cell differs. With the owner's book the cells and
    # their values are said in the page's words, an empty cell in the page's word for the empty choice and a cell or a
    # value the book does not know as gone; without it the cells are named by their keys, as plain words. A cell named
    # as its value adds nothing to the label.
    def table_rows(v, label, word, before, after, person)
      b = flat_cells(table_compact(v, before))
      a = flat_cells(table_compact(v, after))
      bk = book(v, person: person)
      (b.keys | a.keys).reject { |p| b[p] == a[p] }.map do |path|
        cell, e, kin = cell_of(bk, path)
        { label: cell.empty? || cell == word ? label : "#{label} › #{cell}", from: cell_word(bk, e, b[path], kin), to: cell_word(bk, e, a[path], kin) }
      end
    end

    # { [key, inner key, ...] => value } for every cell that holds something
    def flat_cells(h, path = [])
      h.each_with_object({}) do |(k, x), out|
        x.is_a?(Hash) ? out.merge!(flat_cells(x, path + [k.to_s])) : out[path + [k.to_s]] = x
      end
    end

    # A cell's name and its entry in the book: each step's label joined with " › ", a step the book has no entry for
    # said as gone (and the steps after it by their keys); without a book the keys. Third: when the last step is the one
    # gone, the entries beside it (its kin), whose words it is said in when they agree
    def cell_of(bk, path)
      return [path.join(' › '), nil, nil] unless bk

      names = []
      level = bk
      e = nil
      kin = nil
      path.each_with_index do |k, i|
        if level.nil?
          names << k
          next
        end
        e = level[k]
        unless e.is_a?(Hash)
          names << gone_word(k)
          kin = level.values.select { |x| x.is_a?(Hash) } if i == path.size - 1
          level = nil
          e = :gone
          next
        end
        names << e[:label].to_s if e[:label].present?
        level = e[:parts].is_a?(Hash) ? e[:parts].transform_keys(&:to_s) : nil
      end
      [names.join(' › '), e.is_a?(Hash) ? e : nil, kin]
    end

    # A cell's value in the page's words: the empty choice's word for nothing, the value as it is for a text, the word the
    # book gives, else gone. A cell the book no longer knows is said in the words of the cells beside it only when every
    # one of them has a word for it and they all say it alike (the statuses of a tracker that is gone), else its empty side as GK Records' neutral word for empty
    # and its value as it is; core's "(ingen)" only without a book
    def cell_word(bk, e, x, kin = nil)
      if x.nil?
        return e[:empty].to_s if e && e[:empty].present?
        return ::I18n.t(:label_none) unless bk

        w = kin_word(kin) { |k| k[:empty] }
        return w || empty_word
      end
      unless bk && e
        w = bk && kin_word(kin) { |k| k[:words].is_a?(Hash) ? k[:words].transform_keys(&:to_s)[x.to_s] : nil }
        return w || plain_word(x)
      end
      return x.to_s if e[:text] || !e[:words].is_a?(Hash)

      w = e[:words].transform_keys(&:to_s)[x.to_s]
      w ? w.to_s : gone_word(x)
    end

    # The one word the entries beside a gone cell give (the block reads it from an entry): only when every one of them
    # has a word and they all say the same; nil when there are none, when one has no word or when they differ
    def kin_word(kin)
      words = Array(kin).map { |k| yield(k).to_s }
      return nil if words.empty? || words.any?(&:empty?)

      words.uniq.size == 1 ? words.first : nil
    end

    # A value in the words the page shows it in: a select's or a choice's own word, Ja or Nej for a flag, a number or a
    # text as it is, nothing as core's "(ingen)"
    def value_word(v, x)
      return ::I18n.t(:label_none) if x.nil? || x.to_s.strip.empty? || (x.respond_to?(:empty?) && x.empty?)
      return plain_word(x) unless v

      case v.kind
      when 'flag' then ::I18n.t([true, 1, '1', 'true', 'on'].include?(x) ? :general_text_Yes : :general_text_No)
      when 'select', 'choice'
        c = v.choice_list.detect { |e| (e.is_a?(Array) ? e.last : e).to_s == x.to_s }
        c ? (c.is_a?(Array) ? c.first : c).to_s : x.to_s
      else plain_word(x)
      end
    end

    # Any value as text, never JSON: a list joined with commas, a hash as "key: value", nothing as core's "(ingen)"
    def plain_word(x)
      case x
      when nil then ::I18n.t(:label_none)
      when Hash then x.map { |k, y| "#{k}: #{plain_word(y)}" }.join(', ')
      when Array then x.empty? ? ::I18n.t(:label_none) : x.map { |y| plain_word(y) }.join(', ')
      else x.to_s.strip.empty? ? ::I18n.t(:label_none) : x.to_s
      end
    end

    # The target and the two kinds; the page that sets them is GK GUI Stuff's (Utseende, Mitt konto), where the events
    # lead. A person's row is seen by the person and by administrators.
    # Registered whatever the gate says (init.rb): the settings themselves stay behind the gate (register), but a change
    # made while it is closed (a task, a scenario step) is an event all the same; the start choice alone waits for the
    # gate (start!). The target has no address then, since the pages are GK GUI Stuff's.
    def register_records!
      Targets.register(TARGET, model: 'GkRecordsAppearanceSetting',
                               visible: ->(s, user) { user.admin? || (user.logged? && s.user_id == user.id) },
                               editable: ->(_s, user) { user.admin? },
                               label: ->(s) { "#{::I18n.t(:label_gk_records_appearance_setting)}: #{s.name}" },
                               url: lambda { |s|
                                 next nil unless GkRecords.gui?

                                 helpers = Rails.application.routes.url_helpers
                                 path = s.person? ? :gk_gui_stuff_my_path : :gk_gui_stuff_appearance_path
                                 helpers.respond_to?(path) ? helpers.public_send(path) : nil
                               })
      # the changes in words (event_rows), the same rows as the box of Spara on the form page
      Kinds.register_event(KIND, plugin: :gk_records, label_key: 'label_gk_records_event_appearance_setting_changed', target: TARGET,
                                 rows: ->(d, _viewer) { event_rows(d) })
      Kinds.register_event(PERSON_KIND, plugin: :gk_records, label_key: 'label_gk_records_event_appearance_setting_chosen', target: TARGET,
                                        rows: ->(d, _viewer) { event_rows(d, person: true) })
    rescue StandardError => e
      Rails.logger.warn("[gk_records] appearance register not ready: #{e.message}")
    end
  end
end
