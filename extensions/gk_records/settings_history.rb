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

    # {key => [before, after]} for what differs; a plain setting has the one key "value"
    def diff(name, old_raw, new_raw)
      before = flatten(parse(name, old_raw))
      after = flatten(parse(name, new_raw))
      # a setting saved for the first time is compared with its default, so only what was really changed is said
      before = flatten(::Setting.available_settings[name.to_s]&.dig('default')) if old_raw.nil?
      before = {} if old_raw.nil? && !before.is_a?(Hash)
      (before.keys | after.keys).each_with_object({}) do |k, h|
        next if before[k].to_s == after[k].to_s

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

    # Core patch (documented): the reason sent with a settings page goes with every setting that save changes
    module ControllerPatch
      def self.prepended(base)
        base.around_action :gk_records_setting_reason, only: %i[edit plugin]
      end

      private

      # The place records.settings decides; a required reason missing stops the save before any setting is written,
      # and the page comes back with the error
      def gk_records_setting_reason(&block)
        if request.post? && User.current.admin? && params.key?(:settings) && !@sudo_form
          check = GkRecords::Reasons.check('records.settings', params[:gk_records_reason])
          unless check.ok
            flash[:error] = check.error
            return redirect_to(params[:action] == 'plugin' ? plugin_settings_path(params[:id]) : settings_path(tab: params[:tab]))
          end
          return GkRecords::SettingsHistory.with_reason(check.text, &block)
        end
        GkRecords::SettingsHistory.with_reason(params[:gk_records_reason], &block)
      end
    end
  end

  # The reason field on the settings pages, just after the Save of every form (info and choices above, the owner's convention),
  # with a link to the settings' history. Core has no hook in those forms, so the field is placed by script. The field
  # is folded behind the link "Add a reason" (core's add icon), which only opens it; the form's Save saves, with the
  # reason that is written. A required reason folds too and is unfolded with its hint when the form is sent without it. Open, the field and its buttons
  # stand in one framed group; the buttons are core's submit buttons (core's look and hover) that never send the form.
  class SettingsHooks < Redmine::Hook::ViewListener
    def view_layouts_base_body_bottom(context = {})
      c = context[:controller]
      return '' unless c.is_a?(::SettingsController) && User.current.admin? && SettingsHistory.reason_field?
      # core's "Bekräfta ditt lösenord" is rendered in place of the settings page (sudo mode): that form is not a
      # settings form and gets no reason field. A reason already written travels through it as a hidden field.
      return '' if c.instance_variable_get(:@sudo_form)

      label = ::I18n.t(:label_gk_records_setting_reason)
      # no suggestion until a plugin gives a search field of the select2 kind (records_1021-SID-30)
      latest = GkRecords::Reasons.suggest? ? GkRecords::Reasons.suggestions('records.settings')[:latest] : nil
      sug = latest ? ::I18n.t(:text_gk_records_reason_suggest, text: latest.truncate(60)) : nil
      hint = ::I18n.t(:text_gk_records_setting_reason)
      view = context[:hook_caller]
      icon = view.respond_to?(:sprite_icon) ? view.sprite_icon('add').to_s : ''
      # records' stylesheet with the field, which a settings page does not load otherwise: the buttons' height, the
      # square ×, the group's frame and what is hidden
      stylesheet_link_tag('gk_records', plugin: 'gk_records') + javascript_tag(<<~JS)
        (function () {
          var sug = #{sug.to_json}, latest = #{latest.to_json}, need = #{SettingsHistory.reason_required?};
          // a button of the field: core's submit button for core's look and hover; a click on it never sends the form
          var button = function (text, css, fn) {
            var b = document.createElement('button'); b.type = 'submit'; b.className = css; b.textContent = text;
            b.addEventListener('click', function (e) { e.preventDefault(); fn(); });
            return b;
          };
          document.querySelectorAll('#content form').forEach(function (f) {
            if (f.id === 'sudo-form' || f.method.toLowerCase() !== 'post' || f.querySelector('[name=gk_records_reason]')) return;
            // just after the button that saves (the button first, the reason to its right): the reason is
            // written last, where the hand is when the change is made, not above a long page
            var submit = f.querySelector('input[type=submit][name=commit]') || f.querySelector('input[type=submit]');
            var s = document.createElement('span');
            s.className = 'gk-records-setting-reason';
            var l = document.createElement('label'); l.textContent = #{label.to_json};
            var t = document.createElement('textarea'); t.name = 'gk_records_reason'; t.rows = 3; t.cols = 50; t.title = #{hint.to_json};
            t.setAttribute('data-auto-complete', 'true');
            // the browser's "Please fill in this field" in the page's language, plain again once something is written
            t.addEventListener('invalid', function () { if (t.validity.valueMissing) t.setCustomValidity(#{::I18n.t(:error_gk_records_reason_required).to_json}); });
            t.addEventListener('input', function () { t.setCustomValidity(''); });
            t.placeholder = sug || #{::I18n.t(:text_gk_records_reason_write).to_json}; t.id = 'gk_records_reason_' + Math.random().toString(36).slice(2, 8); l.htmlFor = t.id;
            // folded behind the link "Add a reason", which unfolds the field and puts the cursor in it; a folded field
            // is not required to the browser (a hidden required field would stop the form without a word)
            var box = document.createElement('span'); box.hidden = true; box.id = t.id + '_box'; box.className = 'gk-records-setting-reason-box';
            var a = document.createElement('a'); a.href = '#'; a.setAttribute('role', 'button');
            a.className = 'icon icon-add gk-records-setting-reason-unfold'; a.innerHTML = #{icon.to_json};
            var al = document.createElement('span'); al.className = 'icon-label'; al.textContent = #{::I18n.t(:button_gk_records_reason_unfold).to_json};
            a.appendChild(al);
            a.setAttribute('aria-expanded', 'false'); a.setAttribute('aria-controls', box.id);
            var tip = document.createElement('span'); tip.className = 'gk-records-meta gk-records-reason-hint'; tip.hidden = true;
            // shown only for a required reason that is left empty; an optional one never stops the form
            tip.textContent = #{::I18n.t(:text_gk_records_reason_commit_required).to_json};
            var shown = function () { return !box.hidden; };
            var unfold = function (quiet) {
              box.hidden = false; t.required = need; a.setAttribute('aria-expanded', 'true'); a.hidden = true; sizeF(); if (!quiet) t.focus();
            };
            a.addEventListener('click', function (e) { e.preventDefault(); unfold(); });
            a.addEventListener('keydown', function (e) { if (e.key === ' ' || e.key === 'Spacebar') { e.preventDefault(); unfold(); } });
            s.appendChild(a); s.appendChild(box);
            box.appendChild(l); box.appendChild(t);
            if (latest) box.appendChild(button(#{::I18n.t(:button_gk_records_reason_use).to_json}, 'gk-records-reason-use', function () { t.value = latest; t.focus(); }));
            // Use the reason shows what was written as text with Change (the field kept, hidden, so it is sent); the
            // form's Save takes what is written in the same way and sends it
            var used = document.createElement('span'); used.className = 'gk-records-reason-used'; used.hidden = true;
            var usedText = document.createElement('span'); usedText.className = 'gk-records-reason-used-text';
            var isUsed = false;
            // quiet: Save took the reason as the form goes, so the cursor stays where it is
            var setUsed = function (on, quiet) {
              isUsed = on; t.hidden = on; cm.hidden = on; used.hidden = !on; tip.hidden = true;
              sizeF();
              if (on) usedText.textContent = t.value.trim();
              if (quiet) return;
              if (on) ch.focus(); else t.focus();
            };
            var ch = button(#{::I18n.t(:button_gk_records_reason_change).to_json}, 'gk-records-reason-change', function () { setUsed(false); });
            used.appendChild(usedText); used.appendChild(ch);
            var cm = button(#{::I18n.t(:button_gk_records_reason_commit).to_json}, 'gk-records-reason-commit', function () { if (t.value.trim()) setUsed(true); else t.focus(); });
            // the buttons and the link as high as Save, so all stand on its line; Save itself is never turned off for
            // the reason
            var sizeF = function () {
              if (submit && submit.offsetHeight) s.style.setProperty('--gk-reason-btn', submit.offsetHeight + 'px');
            };
            box.appendChild(cm); box.appendChild(used);
            // an unfolded reason folds back (emptied): an optional one then goes without a reason, a required one is
            // asked for again when the form is sent
            var c = button('×', 'gk-records-reason-close', function () {
              t.value = ''; isUsed = false; t.hidden = false; t.required = false; cm.hidden = false; used.hidden = true; tip.hidden = true;
              box.hidden = true; a.hidden = false; a.setAttribute('aria-expanded', 'false'); sizeF(); a.focus();
            });
            c.title = #{::I18n.t(:button_gk_records_reason_close).to_json}; c.setAttribute('aria-label', c.title);
            box.appendChild(c);
            box.appendChild(tip);
            // Save sends what is written (taken as Use the reason takes it); an empty optional reason goes without one,
            // an empty required one stops the form with the hint (a folded one is unfolded first)
            f.addEventListener('submit', function (e) {
              if (isUsed) return;
              if (!shown()) {
                if (!need) return;
                unfold(true);
              } else if (t.value.trim()) {
                setUsed(true, true);
                return;
              } else if (!need) return;
              e.preventDefault(); tip.hidden = false; t.focus();
            }, true);
            t.addEventListener('input', function () { if (t.value.trim()) tip.hidden = true; });
            if (submit) {
              submit.parentNode.insertBefore(s, submit.nextSibling);
              submit.parentNode.insertBefore(document.createTextNode(' '), s);
            } else f.appendChild(s);
            sizeF();
          });
        })();
      JS
    end
  end

  module SettingsHistory
    # Administration > Skäl decides (the place records.settings)
    def self.reason_field? = !GkRecords::Reasons.off?('records.settings')
    def self.reason_required? = GkRecords::Reasons.required?('records.settings')
  end
end
