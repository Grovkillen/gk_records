# frozen_string_literal: true

module GkRecords
  # The gate to GK GUI Stuff, which records requires (IDENTITY.yml, gk_gui_stuff). It is open when GK GUI Stuff answers
  # the gate's questions, its base version (the version without a candidate's suffix) is the lowest one records needs
  # or later, and its own gate is open; candidates of one base version are not told apart.
  #
  # A gate closes only the interface, never a protection or a trace. Closed, the gate closes what a person works with:
  # the pages and the REST API (Gate::Controller, core's 404), the menu rows (their if:), what records draws on other
  # pages (Gate::Listener, and the helpers in ActionView::Base), the core patches that draw or sort (Patches.apply!),
  # the reason places (Reasons.register, so a reason is never required where its field cannot be drawn), the
  # appearance settings (AppearanceSettings.register), the verification places, the readings (Readings.ready?), the
  # choice "med manifest" and what records registers in other plugins' registers. It never closes:
  # * the registers the traces are written through: Targets.register, Kinds.register (events, notes, links,
  #   assessments) and their answers, and the link kind of a #123 in a reason (Reasons.register_link!);
  # * the target and the kind of a changed reason mode (Reasons.register_target!) and of a changed or chosen appearance
  #   setting (AppearanceSettings.register_records!): a change made while the gate is closed is an event all the same;
  # * the writing: Events.write, Assessments.record, Notes.write and the links a reason's #123 gives. An event written
  #   while the gate is closed says so in its details (Gate::DETAIL, with why the gate was closed);
  # * the functions' register (Features.register, request, on?): it answers by the stored value for every plugin, since
  #   protections of other plugins hang on a function;
  # * the identities (Identity.install on every registered target, Identity.boot!) and the system texts' keys;
  # * the core patches that write traces (Patches.protect!): the settings' history and the export log;
  # * the print asked for in the browser: the script on every page and the address that receives it are trace, and
  #   use nothing of GK GUI Stuff;
  # * the project module Events and records' permissions: init.rb registers them whatever the gate says. Core's role
  #   form lists only the permissions that are registered and Role#permissions= writes the whole list, so a role saved
  #   while they were away would lose them, and a project's modules likewise. With the gate closed they open nothing:
  #   the controllers answer 404.
  # A listener on new events (Events.subscribe) is reached while the gate is closed only when its key is in
  # Events::REACHED_WHEN_CLOSED: what follows from an event (a trigger, a request made by itself) is no trace.
  # The settings page says the first thing that is not met in one line of core's own form (<p class="warning">) beside
  # the About box, and that protection and traces hold all the same; the migrations run all the same.

  # The lowest base version the gate opens for; IDENTITY.yml requires the same base and a test holds the two together
  GUI_STUFF_MIN = '1.05.000'

  #   GkRecords.gui_closed -> nil when the gate is open; otherwise the first thing that is not met: :missing (no GK GUI
  #   Stuff), :old (it does not answer open?, or its base version is older than GUI_STUFF_MIN) or :inactive (its own
  #   gate is closed)
  def self.gui_closed
    return :missing unless defined?(::GkGuiStuff)
    return :old unless ::GkGuiStuff.respond_to?(:open?) && ::GkGuiStuff.respond_to?(:version_at_least?) &&
                       ::GkGuiStuff.version_at_least?(GUI_STUFF_MIN)
    return :inactive unless ::GkGuiStuff.open?

    nil
  rescue StandardError
    :missing
  end

  #   GkRecords.gui? -> true when gui_closed has nothing to say
  def self.gui? = gui_closed.nil?

  module Gate
    # The field in an event's details that says the event was written while the gate was closed; its value is why
    # (gui_closed as text: "missing", "old" or "inactive"). An event written with the gate open has no such field.
    DETAIL = 'gk_gui_stuff'
    # The values the field takes, as they are stored
    WAYS = %w[missing old inactive].freeze

    # The field as a reader is told it, in the reader's language: "GK GUI Stuff: missing", "GK GUI Stuff: too old",
    # "GK GUI Stuff: not active". The event log, its CSV and the REST API say these words; the stored details keep the
    # key and the value. detail? is true only for the field with one of its own values, so a detail of the same name
    # that an owner plugin wrote with another value is shown as it is.
    def self.detail?(field, value) = field.to_s == DETAIL && value.is_a?(String) && WAYS.include?(value)
    # A language without the words says the plugin's name and the stored value, never a missing translation.
    def self.label = ::I18n.t(:label_gk_records_gate_detail, default: 'GK GUI Stuff')
    def self.word(value) = ::I18n.t(:"text_gk_records_gate_#{value}", default: value.to_s)
    def self.line(value) = "#{label}: #{word(value)}"

    # The line of an event's details, or nil for an event written with the gate open
    def self.line_of(details)
      value = details.is_a?(Hash) ? details[DETAIL] : nil
      detail?(DETAIL, value) ? line(value) : nil
    end

    # The hook methods a view or controller listener answers (view_*, controller_*, model_*). Redmine asks a listener
    # respond_to?(hook) once and keeps the answer (Redmine::Hook.hook_listeners), so a closed gate keeps every hook of
    # a listener that includes this silent. A listener is registered as soon as its class is defined
    # (Listener.inherited), so the gate is in the listener and not in init.rb. The export log's listener does not
    # include it: the print script is trace, and its choice "med manifest" asks the gate itself.
    HOOK = /\A(view|controller|model)_/

    module Listener
      def respond_to?(name, include_all = false)
        return false if HOOK.match?(name.to_s) && !GkRecords.gui?

        super
      end
    end

    # Every records controller (the pages and the REST API) is closed without GK GUI Stuff: core's 404; all but the
    # one that receives a print asked for in the browser (GkRecordsPrintsController), which is trace. A plain
    # before_action, after the ones ApplicationController has (the session, the user, the language), so that the 404 is
    # drawn for the person and in the language of the request; before the controller's own (require_login and the like)
    module Controller
      def self.included(base)
        base.before_action :gk_records_gate
      end

      private

      def gk_records_gate
        render_404 unless GkRecords.gui?
      end
    end
  end
end
