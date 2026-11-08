# frozen_string_literal: true

# Added in 1.05.000: moves what an installation stored before the register into
# gk_records_appearance_settings, so that nothing is lost when the build comes in.
# What is moved: the levels, values and persons' choices that the plugins kept in their own places before
# 1.05.000: GK GUI Stuff's modules and values (Setting.plugin_gk_gui_stuff) and each person's choices
# (gk_gui_stuff_user_settings), GK Core Stuff's looks and modules (Setting.plugin_gk_core_stuff, each person's looks
# switched off in UserPreference), GK Tags' sidebar numbers (Setting.plugin_gk_tags), people's chat icons (a GUI Stuff
# module before), and the three functions that became appearance settings (gk_records_features rows tags.sidebar,
# icons.in_text and workflow_rules.bands_in_lists). Each level is the one the old code answered, also where nothing
# was stored (an old default that was on stays on); a setting that always held before (the instance band, the account
# menu's colours, the alignment, the AM/PM space, a mark's note text) is written forced. The instance's Like Redmine
# (core_like) switched every module off and does so here; a person's is the person's Like Redmine for me (key *), which
# in the register also covers the other plugins' optional settings and the counters at the name.
# Numbers outside the new limits are brought inside them; a flag stored empty keeps its old default.
# Runs once, only in an installation with data (a project exists) whose register is still empty, and only for the
# plugins installed now; a new installation gets nothing. The old places are left as they were. Every value written
# is checked against the declaration as it stood in 1.05.000, kept here, never against the plugins' code as it is later.
# Every row written is an event with the system's reason "migration" (text_gk_records_reason_migration, kept as a key
# so that History shows it in the reader's language): an instance row a change of the setting, a person's row the
# person's own choice; before is empty, there was no row.
# Down: nothing; the old places were not touched, and the register keeps what it holds.
class MoveAppearanceSettingsToRegister < ActiveRecord::Migration[6.1]
  # an instant written in UTC with its offset, as GkRecordsInstant writes the plugin's time columns
  class Instant < ActiveRecord::Type::DateTime
    def serialize(value)
      v = super
      v.respond_to?(:utc) ? v.getutc.strftime('%Y-%m-%d %H:%M:%S.%6N+00:00') : v
    end
  end

  # the register's row, without the plugin's model
  class Row < ActiveRecord::Base
    self.table_name = 'gk_records_appearance_settings'
    attribute :created_at, Instant.new
    attribute :updated_at, Instant.new
  end

  # the reason note and the event, without the plugin's models (Events.write as it stood in 1.05.000)
  class Note < ActiveRecord::Base
    self.table_name = 'gk_records_notes'
    attribute :created_at, Instant.new
  end

  class Event < ActiveRecord::Base
    self.table_name = 'gk_records_events'
    attribute :created_at, Instant.new
  end

  TARGET = 'appearance_setting'
  KIND = 'appearance_setting_changed'
  PERSON_KIND = 'appearance_setting_chosen'
  REASON = 'text_gk_records_reason_migration'

  MODES = %w[off optional forced].freeze
  # GK GUI Stuff's modules: [on in a new installation before 1.05.000, safety (off and forced only)]
  GUI_MODULES = {
    'link_preview' => [false, false], 'members_by_group' => [false, false], 'report_clarity' => [false, false],
    'long_fields' => [false, false], 'notes_collapse' => [false, false], 'private_notes_collapse' => [false, false],
    'code_blocks' => [false, false], 'attachments_collapse' => [false, false], 'mailto_copy' => [false, false],
    'inline_copy' => [false, false], 'code_copy' => [false, false], 'week_number' => [false, false], 'arrows' => [false, false],
    'quick_done' => [false, false], 'parent_link' => [false, false], 'recent_pages' => [false, false], 'openers' => [false, false],
    'wave' => [false, false], 'corner' => [false, false], 'history_navigator' => [false, false], 'fullscreen' => [false, false],
    'branch_jump' => [false, false], 'flash_timeout' => [false, false], 'custom_mark' => [false, false],
    'short_descriptions' => [true, false], 'scroll_shade' => [true, false], 'hide_disabled' => [false, false],
    'filled_badges' => [false, false], 'key_suggest' => [true, false], 'image_crop' => [true, false], 'user_status' => [false, false],
    'sticky_columns' => [false, false], 'overdue_mark' => [false, false], 'gantt_width' => [true, false], 'gantt_fill' => [false, false],
    'calendar_compact' => [true, false], 'collapse_all' => [false, false], 'list_filter' => [true, false],
    'select_search' => [true, false], 'sticky_save' => [true, false], 'settings_frame' => [true, false],
    'attachment_sizes' => [true, false], 'admin_groups' => [true, false],
    'help_link' => [false, true], 'declutter' => [false, true], 'footer_text' => [false, true], 'login_warning' => [false, true]
  }.freeze
  # number: [the new default, min, max, step, the old lowest]; flag: [the new default]
  GUI_VALUES = {
    'link_preview' => { 'preview_delay_ms' => [:number, 500, 0, 3000, 50, 0] },
    'attachments_collapse' => { 'fold_attachments' => [:number, 6, 2, 100, 1, 2], 'attachments_newest' => [:flag, false] },
    'flash_timeout' => { 'flash_seconds' => [:number, 8, 0, 120, 1, 0] },
    'wave' => { 'wave_opacity_pct' => [:number, 60, 0, 100, 5, 0], 'wave_first_ms' => [:number, 1600, 0, 5000, 100, 0],
                'wave_ms' => [:number, 600, 0, 5000, 50, 0], 'wave_min_ms' => [:number, 400, 0, 5000, 50, 0],
                'wave_start_delay_ms' => [:number, 0, 0, 5000, 50, 0], 'loading_delay_ms' => [:number, 1300, 200, 10_000, 100, 200],
                'wave_hide_flash' => [:flag, true] },
    'corner' => { 'corner_max_entries' => [:number, 20, 1, 100, 1, 1] },
    'short_descriptions' => { 'description_lines' => [:number, 1, 1, 10, 1, 1] },
    'login_warning' => { 'login_warning_animate' => [:flag, true], 'login_warning_endless' => [:flag, false] },
    'fold_height' => { 'fold_height_px' => [:number, 320, 80, 2000, 20, 80] },
    'notices' => { 'notice_seconds' => [:number, 6, 4, 60, 1, 4], 'notice_countdown' => [:flag, true] },
    'due_soon' => { 'due_soon_days' => [:number, 3, 0, 60, 1, 0] },
    'beat' => { 'beat_seconds' => [:number, 30, 0, 600, 5, 0] }
  }.freeze
  GUI_SHARED = %w[fold_height notices due_soon beat].freeze
  GUI_TABLES = { 'declutter' => 'declutter', 'quick_done' => 'quick_done_status', 'admin_groups' => 'admin_rows' }.freeze
  MARK_STYLES = %w[diamond stripe italic].freeze
  ICONS = %w[core both icon].freeze
  PLACES = %w[out icon menu].freeze
  # [the old setting, the new value's name, the choices, Redmine's own, the new default]
  GUI_LAYOUT = { 'icons_tabs' => ['icons_tabs', 'mode', ICONS, 'core', 'icon'], 'icons_issue' => ['icons_issue', 'mode', ICONS, 'core', 'icon'],
                 'icons_other' => ['icons_other', 'mode', ICONS, 'core', 'icon'],
                 'layout_sidebar' => ['layout_sidebar', 'side', %w[after before hidden], 'after', 'before'],
                 'layout_header' => ['layout_header', 'height', %w[tall compact], 'tall', 'compact'] }.freeze
  # GK Core Stuff's looks: the old default level
  LOOKS = {
    'ajax_indicator' => 'off', 'block_icons' => 'optional', 'control_heights' => 'optional', 'field_widths' => 'optional',
    'heading_badge' => 'optional', 'label_rows' => 'optional', 'list_align' => 'optional', 'list_badge' => 'optional',
    'list_checkbox' => 'optional', 'list_hash' => 'off', 'list_sort' => 'optional', 'menu_icons' => 'optional',
    'native_texts' => 'optional', 'scm_table' => 'optional', 'settings_widths' => 'optional', 'sidebar_spacing' => 'optional',
    'submit_word' => 'off', 'warning_balance' => 'optional'
  }.freeze
  CORE_DEFAULTS = { 'done_ratio_text' => '0', 'done_ratio_text_position' => 'right', 'done_ratio_text_zero' => '1', 'done_ratio_text_full' => '1',
                    'done_ratio_text_plate' => '0', 'time_ampm_nbsp' => '1', 'footer_version' => '0' }.freeze
  POSITIONS = %w[right over under hidden].freeze
  MOVED_FUNCTIONS = { 'gk_tags' => 'tags.sidebar', 'gk_icons' => 'icons.in_text', 'gk_workflow_rules' => 'workflow_rules.bands_in_lists' }.freeze

  def up
    return unless table_exists?(:gk_records_appearance_settings)
    return if Row.exists?
    return unless table_exists?(:projects) && select_value('SELECT 1 FROM projects LIMIT 1').present?

    @instance = {}
    @people = Hash.new { |h, k| h[k] = {} }
    gui_stuff if installed?(:gk_gui_stuff)
    core_stuff if installed?(:gk_core_stuff)
    tags if installed?(:gk_tags)
    moved_functions
    write!
  end

  def down
    # nothing: the old places were left as they were
  end

  private

  def installed?(plugin) = defined?(::Redmine::Plugin) && ::Redmine::Plugin.registered_plugins.key?(plugin)

  # a plugin's stored settings as a plain hash with string keys, or nil when there is no row
  def plugin_settings(plugin)
    raw = select_value("SELECT value FROM settings WHERE name = #{connection.quote("plugin_#{plugin}")}")
    return nil if raw.blank?

    permitted = [Symbol, ActiveSupport::HashWithIndifferentAccess]
    permitted << ActionController::Parameters if defined?(ActionController::Parameters)
    v = YAML.safe_load(raw, permitted_classes: permitted, aliases: true)
    v = v.to_unsafe_h if v.respond_to?(:to_unsafe_h)
    v.is_a?(Hash) ? plain(v) : {}
  rescue StandardError => e
    say("plugin_#{plugin} not read: #{e.class} #{e.message}")
    {}
  end

  def plain(h) = JSON.parse(h.to_json)

  def flag(raw, default) = raw.nil? || raw.to_s == '' ? default : raw.to_s == '1'

  # as the old Switches.int: digits at or above the old lowest, else the default; then inside the new limits, on a step
  def number(raw, spec)
    _, default, min, max, step, old_min = spec
    s = raw.to_s
    v = s.match?(/\A\d+\z/) && s.to_i >= old_min ? s.to_i : default
    v = v.clamp(min, max)
    v - ((v - min) % step)
  end

  def value(raw, spec)
    spec.first == :flag ? flag(raw, spec[1]) : number(raw, spec)
  end

  def set(key, mode: nil, values: {})
    row = (@instance[key] ||= { 'mode' => nil, 'values' => {} })
    row['mode'] = mode if mode
    row['values'].merge!(values)
  end

  def person(user_id, key, mode: nil, values: {})
    row = (@people[user_id.to_i][key] ||= { 'mode' => nil, 'values' => {} })
    row['mode'] = mode if mode
    row['values'].merge!(values)
  end

  # ---------------------------------------------------------------- GK GUI Stuff (and people's chat icons)
  def gui_mode(mods, key, default_on, safety)
    h = mods[key].is_a?(Hash) ? mods[key] : {}
    m = h['mode'].to_s
    return(safety && m == 'optional' ? 'forced' : m) if MODES.include?(m)
    return 'off' unless flag(h['enabled'], default_on)

    !safety && flag(h['user_choice'], true) ? 'optional' : 'forced'
  end

  def gui_people
    return [] unless table_exists?(:gk_gui_stuff_user_settings)

    select_rows('SELECT user_id, settings FROM gk_gui_stuff_user_settings').filter_map do |uid, json|
      data = JSON.parse(json.to_s)
      data.is_a?(Hash) ? [uid.to_i, data] : nil
    rescue JSON::ParserError
      nil
    end
  end

  def gui_stuff
    s = plugin_settings(:gk_gui_stuff) || {}
    mods = s['modules'].is_a?(Hash) ? s['modules'] : {}
    core_like = s['core_like'].to_s == '1'
    people = gui_people

    GUI_MODULES.each do |name, (default_on, safety)|
      mode = core_like ? 'off' : gui_mode(mods, name, default_on, safety)
      set("gui_stuff.#{name}", mode: mode, values: gui_values(s, name))
    end
    GUI_SHARED.each { |name| set("gui_stuff.#{name}", values: gui_values(s, name)) }
    # always there before: the instance band (for the roles it is shown for), the account menu's colours, the alignment
    %w[instance_band account_menu align].each { |name| set("gui_stuff.#{name}", mode: 'forced') }
    if installed?(:gk_people)
      set('people.name_chat', mode: core_like ? 'off' : gui_mode(mods, 'name_chat', false, false))
    end
    gui_layout(s, people, core_like)
    gui_people_choices(people)
  end

  def gui_values(s, name)
    out = (GUI_VALUES[name] || {}).to_h { |n, spec| [n, value(s[n], spec)] }
    out.reject! { |n, v| v == GUI_VALUES[name][n][1] }
    if (t = GUI_TABLES[name]) && s[t].is_a?(Hash) && s[t].any?
      out[t] = s[t]
    end
    case name
    when 'footer_text'
      text = s['footer_text'].to_s.strip.first(500)
      out['footer_text'] = text if text.present?
    when 'custom_mark'
      style = s['custom_mark_style'].to_s
      out['custom_mark_style'] = style if MARK_STYLES.include?(style) && style != 'diamond'
    when 'help_link'
      kind = s['help_kind'].to_s.presence || 'core'
      help = { 'kind' => kind, 'url' => s['help_url'].to_s, 'wiki_project' => s['help_wiki_project'].to_s, 'wiki_page' => s['help_wiki_page'].to_s }
      out['help_link'] = help if kind != 'core' || help.except('kind').values.any?(&:present?)
    end
    out
  end

  def valid_place?(key, place) = key.to_s.start_with?('core_') ? ICONS.include?(place.to_s) : PLACES.include?(place.to_s)

  def places(h) = (h.is_a?(Hash) ? h.select { |k, v| valid_place?(k, v) } : {})

  # the placements, the icons per area, the sidebar and the header had no level: everyone was free to choose; on when
  # the administrator chose other than Redmine's own or a person chose
  def gui_layout(s, people, core_like)
    admin = places(s['placements'])
    chosen = people.any? { |_uid, d| places(d['placements']).any? }
    set('gui_stuff.placements', mode: !core_like && (admin.any? || chosen) ? 'optional' : 'off',
                                values: admin.any? ? { 'placements' => admin } : {})
    GUI_LAYOUT.each do |key, (old, name, choices, own, _default)|
      v = choices.include?(s[old].to_s) ? s[old].to_s : own
      anyone = people.any? { |_uid, d| choices.include?(d[old].to_s) }
      set("gui_stuff.#{key}", mode: !core_like && (v != own || anyone) ? 'optional' : 'off', values: { name => v })
    end
    # the counters at the name were always there, also under the instance's Like Redmine
    set('gui_stuff.personal_count', mode: 'optional')
  end

  def gui_people_choices(people)
    people.each do |uid, d|
      person(uid, '*', mode: 'on') if d['core_like'].to_s == '1'
      (d['modules'].is_a?(Hash) ? d['modules'] : {}).each do |name, v|
        next unless v.to_s == '0'

        if name == 'name_chat'
          person(uid, 'people.name_chat', mode: 'off') if installed?(:gk_people)
        elsif GUI_MODULES.key?(name) && !GUI_MODULES[name][1]
          person(uid, "gui_stuff.#{name}", mode: 'off')
        end
      end
      case d['count_mode'].to_s
      when 'none' then person(uid, 'gui_stuff.personal_count', mode: 'off')
      when 'zero' then person(uid, 'gui_stuff.personal_count', values: { 'shown_as' => 'zero' })
      else person(uid, 'gui_stuff.personal_count', values: { 'shown_as' => 'split' }) if d['count_split'].to_s == '1'
      end
      p = places(d['placements'])
      person(uid, 'gui_stuff.placements', values: { 'placements' => p }) if p.any?
      GUI_LAYOUT.each do |key, (old, name, choices, _own, _default)|
        person(uid, "gui_stuff.#{key}", values: { name => d[old].to_s }) if choices.include?(d[old].to_s)
      end
    end
  end

  # ---------------------------------------------------------------- GK Core Stuff
  def core_stuff
    s = CORE_DEFAULTS.merge(plugin_settings(:gk_core_stuff) || {})
    LOOKS.each do |name, default|
      raw = s["look_#{name}"].to_s
      mode = if MODES.include?(raw) then raw
             elsif raw == '1' then 'optional'
             elsif raw == '0' then 'off'
             else default
             end
      set("core_stuff.#{name}", mode: mode)
    end
    values = {}
    pos = s['done_ratio_text_position'].to_s
    values['done_ratio_text_position'] = pos if POSITIONS.include?(pos) && pos != 'right'
    { 'done_ratio_text_zero' => true, 'done_ratio_text_full' => true, 'done_ratio_text_plate' => false }.each do |n, default|
      v = s[n].to_s == '1'
      values[n] = v if v != default
    end
    set('core_stuff.done_ratio_text', mode: s['done_ratio_text'].to_s == '1' ? 'forced' : 'off', values: values)
    set('core_stuff.time_ampm_nbsp', mode: s['time_ampm_nbsp'].to_s == '1' ? 'forced' : 'off')
    set('core_stuff.footer_version', mode: s['footer_version'].to_s == '1' ? 'forced' : 'off')
    core_people
  end

  def core_people
    return unless table_exists?(:user_preferences)

    ::UserPreference.find_each do |pref|
      others = pref.others || {}
      list = others[:gk_core_stuff_looks_off] || others['gk_core_stuff_looks_off']
      Array(list).map(&:to_s).select { |name| LOOKS.key?(name) }.each { |name| person(pref.user_id, "core_stuff.#{name}", mode: 'off') }
    rescue StandardError => e
      say("preferences of user #{pref.user_id} not read: #{e.class} #{e.message}")
    end
  end

  # ---------------------------------------------------------------- GK Tags, and the functions that moved
  def tags
    s = plugin_settings(:gk_tags) || {}
    values = {}
    { 'sidebar_limit' => [15, 1000], 'sidebar_top' => [5, 100] }.each do |n, (default, max)|
      v = s[n].to_s.to_i
      values[n] = [v, max].min if v.positive? && v != default
    end
    set('tags.sidebar', values: values)
    # the note of one's own mark was always written out before
    set('tags.note_text', mode: 'forced')
  end

  def moved_functions
    return unless table_exists?(:gk_records_features)

    on = select_rows("SELECT key, enabled FROM gk_records_features WHERE key IN (#{MOVED_FUNCTIONS.values.map { |k| connection.quote(k) }.join(', ')})")
         .select { |_k, e| [true, 't', 'true', 1, '1'].include?(e) }.map(&:first)
    MOVED_FUNCTIONS.each { |plugin, key| set(key, mode: 'forced') if on.include?(key) && installed?(plugin.to_sym) }
  end

  # ---------------------------------------------------------------- the rows
  def write!
    # the reason's text revisions first, so that the notes written after them read the text they were written with
    reason = reason_text
    now = Time.current
    rows = []
    @instance.each do |key, h|
      next if (h['mode'].nil? || h['mode'] == 'off') && h['values'].empty?

      rows << { key: key, user_id: 0, mode: h['mode'], values_json: h['values'].presence&.to_json, created_at: now, updated_at: now }
    end
    @people.each do |uid, keys|
      next unless uid.positive?

      keys.each do |key, h|
        next if h['mode'].nil? && h['values'].empty?

        rows << { key: key, user_id: uid, mode: h['mode'], values_json: h['values'].presence&.to_json, created_at: now, updated_at: now }
      end
    end
    rows.each { |r| record!(Row.create!(r), reason, now) }
    say("#{rows.count { |r| r[:user_id].zero? }} rows for the instance and #{rows.count { |r| r[:user_id].positive? }} for persons moved to the register")
  end

  # The reason's text in the instance's language, its cells in gk_records_text_revisions brought up to date as
  # SystemText does before a system text is written; nil when the notes or the events are not there
  def reason_text
    return nil unless table_exists?(:gk_records_notes) && table_exists?(:gk_records_events)

    if defined?(::GkRecords::SystemText)
      begin
        ::GkRecords::SystemText.ensure_current!(REASON)
      rescue StandardError => e
        say("the reason's text revisions not written: #{e.class} #{e.message}")
      end
    end
    locale = (::Setting.default_language.presence if defined?(::Setting)) || ::I18n.default_locale
    ::I18n.t(REASON, locale: locale, default: ::I18n.t(REASON, locale: :en, default: 'migration'))
  end

  # one event per moved row: the level and the values it holds, before empty, by the system, with the reason note
  def record!(row, reason, now)
    return unless reason

    details = { 'appearance_setting' => row.key }
    details['mode'] = [nil, row.mode] if row.mode
    values = row.values_json.present? ? JSON.parse(row.values_json) : {}
    details['values'] = values.to_h { |n, v| [n, [nil, v]] } if values.any?
    note = Note.create!(target_type: TARGET, target_id: row.id, kind: 'reason', body: reason, origin: 'system',
                        text_key: REASON, text_values: '{}', created_at: now)
    Event.create!(target_type: TARGET, target_id: row.id, kind: row.user_id.to_i.zero? ? KIND : PERSON_KIND,
                  details: details.to_json, reason_note_id: note.id, origin: 'system', created_at: now)
  end
end
