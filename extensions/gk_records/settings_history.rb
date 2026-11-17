# frozen_string_literal: true

module GkRecords
  # Settings are change managed like everything else: every changed setting, core's own and every plugin's, is a
  # records event on the setting with who, when, before and after, and the reason when one was given. Caught in
  # the model, so the pages, the API, rake and scripts are logged alike; a change with no person (a start
  # script) is the system's.
  # A plugin's settings are one hash: the event says which keys changed (nested keys joined with a dot).
  # Values that look like secrets are never written, only that they changed.
  module SettingsHistory
    TARGET = 'setting'
    KIND = 'setting_changed'
    SECRET = /password|passwd|secret|token|api_key|private/i
    MAX = 300

    module_function

    def register!
      Targets.register(TARGET, model: 'Setting',
                               visible: ->(_s, user) { user.admin? }, editable: ->(_s, user) { user.admin? },
                               label: ->(s) { label(s.name) }, url: ->(s) { url(s.name) })
      Kinds.register_event(KIND, plugin: :gk_records, label_key: 'label_gk_records_event_setting_changed', target: TARGET)
    end

    def plugin_id(name) = name.to_s[/\Aplugin_(.+)\z/, 1]

    def label(name)
      if (id = plugin_id(name))
        pl = Redmine::Plugin.registered_plugins[id.to_sym]
        "#{::I18n.t(:label_plugins)}: #{pl ? pl.name : id}"
      else
        ::I18n.t("setting_#{name}", default: name.to_s)
      end
    end

    def url(name)
      id = plugin_id(name)
      id ? { controller: 'settings', action: 'plugin', id: id } : { controller: 'settings', action: 'index' }
    end

    # The reason given with the save (the settings pages send gk_records_reason), for every setting the request changes
    def with_reason(text)
      prev = Thread.current[:gk_records_setting_reason]
      Thread.current[:gk_records_setting_reason] = text.to_s.strip.presence
      yield
    ensure
      Thread.current[:gk_records_setting_reason] = prev
    end

    def reason = Thread.current[:gk_records_setting_reason]

    def parse(name, raw)
      return nil if raw.nil?

      spec = ::Setting.available_settings[name.to_s]
      return raw.to_s unless spec && spec['serialized'] && raw.is_a?(String)

      YAML.safe_load(raw, permitted_classes: Rails.configuration.active_record.yaml_column_permitted_classes)
    rescue StandardError
      raw.to_s
    end

    def flatten(value, prefix = nil, out = {})
      if value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
        value.to_h.each { |k, v| flatten(v, [prefix, k].compact.join('.'), out) }
      else
        out[prefix || 'value'] = value.is_a?(Array) ? value.map(&:to_s).join(', ') : value.to_s
      end
      out
    end

    def shown(key, value)
      return nil if value.nil?
      return ::I18n.t(:text_gk_records_setting_hidden) if SECRET.match?(key.to_s)

      value.to_s.length > MAX ? "#{value.to_s.first(MAX)}..." : value.to_s
    end

    # Line endings are no change: a value that differs only in CRLF, CR or LF (a multi-line text saved from a browser
    # form against one stored by a script, such as the welcome text or the email footer) is the same value. Only the
    # comparison reads them alike; what is written as before and after is the value as it was and as it is.
    def same?(before, after)
      before.to_s == after.to_s || one_line_ending(before) == one_line_ending(after)
    end

    def one_line_ending(value) = value.to_s.gsub(/\r\n?/, "\n")

    # {key => [before, after]} for what differs; a plain setting has the one key "value"
    def diff(name, old_raw, new_raw)
      before = flatten(parse(name, old_raw))
      after = flatten(parse(name, new_raw))
      # a setting saved for the first time is compared with its default, so only what was really changed is said
      before = flatten(::Setting.available_settings[name.to_s]&.dig('default')) if old_raw.nil?
      before = {} if old_raw.nil? && !before.is_a?(Hash)
      (before.keys | after.keys).each_with_object({}) do |k, h|
        next if same?(before[k], after[k])

        key = k == 'value' ? name.to_s : k
        h[k] = [shown(key, before[k]), shown(key, after[k])]
      end
    end

    def record(setting, old_raw, new_raw)
      return unless Targets.find(TARGET) && Kinds.find(:event, KIND)

      changes = diff(setting.name, old_raw, new_raw)
      return if changes.empty?

      actor = User.current
      details = { 'setting' => setting.name }.merge(changes)
      Events.write(setting, KIND, details: details, reason: reason, user: actor.logged? ? actor : nil,
                                  origin: actor.logged? ? 'human' : 'system')
    rescue StandardError => e
      Rails.logger.warn("[gk_records] setting change not recorded for #{setting.name}: #{e.class} #{e.message}")
    end

    # Core patch (documented): the model tells records after every save that changed the value
    module SettingPatch
      def self.prepended(base)
        base.after_save :gk_records_setting_changed
      end

      private

      def gk_records_setting_changed
        return unless saved_change_to_value?

        old, new = saved_change_to_value
        old = nil if saved_change_to_id?
        GkRecords::SettingsHistory.record(self, old, new)
      end
    end

    # Core patch (documented): the reason sent with a settings page goes with every setting that save changes; on a
    # plugin's settings page also the verification levels drawn there (records' and people's places), saved with the
    # page: checked before core saves anything, carried out after
    module ControllerPatch
      def self.prepended(base)
        base.around_action :gk_records_setting_reason, only: %i[edit plugin]
        base.around_action :gk_records_verification_levels, only: %i[plugin]
      end

      private

      # The levels posted with a plugin's settings (Verification::LEVELS_PARAM), only by an administrator: when one
      # is missing a level to move to or a reason, nothing is saved and the page is drawn again with what was posted
      # and the error. Records' own form never writes back an old copy of the places' choices (carry_places!). After
      # core saved the settings, the records are moved and the levels written.
      def gk_records_verification_levels
        return yield unless GkRecords.gui? # the levels are drawn only on an open settings page (gate.rb)

        v = GkRecords::Verification
        posting = request.post? && User.current.admin? && params.key?(:settings) && !@sudo_form
        return yield unless posting

        v.carry_places!(params[:settings]) if params[:id].to_s == 'gk_records'
        raw = params[v::LEVELS_PARAM]
        return yield if raw.blank?

        # judged by the settings this form posts (a review rule that reads one of them sees the page's new value)
        posted = params[:settings].respond_to?(:to_unsafe_h) ? params[:settings].to_unsafe_h : params[:settings]
        plans, errors = v.with_posted_settings(params[:id], posted) { v.check_levels(raw) }
        return gk_records_levels_refused(v.levels_refused(errors), posted) if errors.any?

        yield
        return unless response.redirect? && flash[:error].blank?

        ok, error = v.apply_levels!(plans, user: User.current, saved: true)
        flash[:error] = error unless ok
      end

      # core's plugin settings page drawn again with the posted settings, as the form was sent; back to the page
      # when it cannot be drawn. The levels are drawn by the posted settings, as they were checked
      def gk_records_levels_refused(message, posted = nil)
        @plugin = Redmine::Plugin.find(params[:id])
        @partial = @plugin.settings[:partial]
        @settings = params[:settings].permit!.to_h
        flash.now[:error] = message
        GkRecords::Verification.with_posted_settings(params[:id], posted) { render action: 'plugin' }
      rescue StandardError => e
        raise if performed?

        Rails.logger.warn("[gk_records] the settings page not drawn again: #{e.class} #{e.message}")
        flash[:error] = message
        redirect_to plugin_settings_path(params[:id])
      end

      # The place records.settings decides; a required reason missing stops the save before any setting is written,
      # and the page comes back with the error. Required only for a form that carries the field (its view calls the
      # hook beside Save): a form without it is never stopped for a reason it cannot take
      def gk_records_setting_reason(&block)
        drawn = GkRecords::SettingsHistory.reason_drawn?(plugin: params[:action] == 'plugin', tab: params[:tab])
        if request.post? && User.current.admin? && params.key?(:settings) && !@sudo_form && drawn
          check = GkRecords::Reasons.check('records.settings', params[:gk_records_reason])
          unless check.ok
            flash[:error] = check.error
            return redirect_to(params[:action] == 'plugin' ? plugin_settings_path(params[:id]) : settings_path(tab: params[:tab]))
          end
          return GkRecords::SettingsHistory.with_reason(check.text, &block)
        end
        # a save that is not asked for the reason (a form without the field) keeps what was sent with it all the
        # same, but never while the place is off: Off keeps no reason, whatever was sent. Neither while the gate to GK
        # GUI Stuff is closed (gate.rb): no form carries the field then, so the change is an event without a reason
        keep = GkRecords.gui? && GkRecords::SettingsHistory.reason_field?
        GkRecords::SettingsHistory.with_reason(keep ? params[:gk_records_reason] : nil, &block)
      end
    end
  end

  # The reason on the settings pages: GK GUI Stuff's reason (gk_gui_stuff_reason_block, name gk_records_reason) on a
  # row of its own under core's Save of every settings form, drawn by the hook beside Save in every settings tab and on
  # a plugin's settings page (view_settings_form_save_after, gk_core_stuff's more_view_hooks). A form whose view does
  # not call the hook gets no reason. Core's Save stays core's; the guard is in assets (gk_records_reason.js, as the
  # shell's): a required reason left empty stops the form with the block's error and the cursor in the reason. Core's
  # "Bekräfta ditt lösenord" (sudo mode) is not a settings form and gets none; a reason written travels through it as a
  # hidden field.
  class SettingsHooks < Redmine::Hook::ViewListener
    include GkRecords::Gate::Listener # silent without GK GUI Stuff (gate.rb)

    # need: whether this form's reason is required (the same answer the controller gives when the form is sent)
    def view_settings_form_save_after(context = {})
      return '' unless User.current.admin? && SettingsHistory.reason_field?
      return '' if context[:controller]&.instance_variable_get(:@sudo_form)

      view = context[:hook_caller]
      need = SettingsHistory.reason_required? && SettingsHistory.reason_drawn?(plugin: context[:plugin].present?, tab: context[:tab])
      @n = (@n || 0) + 1
      block = view.gk_gui_stuff_reason_block(required: need, id: "gk-records-setting-reason-#{@n}", name: 'gk_records_reason')
      content_tag('span', block, class: 'gk-records-reason-wrap gk-records-setting-reason',
                                 data: { gk_records_reason: 'records.settings', gk_records_reason_need: need ? '1' : '0' })
    end
  end

  module SettingsHistory
    # Administration > Skäl decides (the place records.settings)
    def self.reason_field? = !GkRecords::Reasons.off?('records.settings')
    def self.reason_required? = GkRecords::Reasons.required?('records.settings')

    # The settings view a save comes from, the one answer for the controller and the hook: a plugin's settings page
    # is settings/plugin; a tab is its partial, where no tab is the General tab (its form sends none) and the API tab
    # is settings/_api in every series. nil for a tab no settings view calling the hook is known by (without the
    # list, gk_core_stuff's hook? decides for the view alone).
    def self.reason_view(plugin:, tab:)
      return 'settings/plugin' if plugin

      name = tab.to_s.presence || 'general'
      view = %w[api integrations].include?(name) ? 'settings/_api' : "settings/_#{name}"
      known = ::GkCoreStuff::MoreViewHooks::HOOK_VIEWS[:view_settings_form_save_after] if defined?(::GkCoreStuff::MoreViewHooks::HOOK_VIEWS)
      known.nil? || known.include?(view) ? view : nil
    end

    # Whether a settings form carries the reason field: its view calls the hook beside Save, asked of gk_core_stuff
    # by the view's name. Only a known view without the hook goes without: a tab no view is known by is asked for
    # the reason as before, so a save can never slip past a required reason by naming another tab. Without
    # gk_core_stuff no form carries the field, and neither while the gate to GK GUI Stuff is closed (the field is GK
    # GUI Stuff's reason block): the change is then written as an event without a reason, never stopped for one.
    def self.reason_drawn?(plugin:, tab:)
      return false unless GkRecords.gui?
      return false unless defined?(::GkCoreStuff) && ::GkCoreStuff.respond_to?(:hook?)

      view = reason_view(plugin: plugin, tab: tab)
      view ? ::GkCoreStuff.hook?(:view_settings_form_save_after, view: view) : true
    rescue StandardError
      true
    end
  end
end
