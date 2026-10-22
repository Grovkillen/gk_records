# frozen_string_literal: true

module GkRecords
  #   GkRecords::Verification.get(obj)                    # => 'unverified' or nil
  #   GkRecords::Verification.set!(obj, 'hypothesis', user: User.current, reason: 'Inte prövat än')
  # A thing without a row has no status said (nil), which is not the same as unverified.
  #
  # 1. "En post blir Verifierad bara genom en godkänd granskning i signoff... Ingen kan välja Verifierad direkt."
  # set!(obj, 'verified') is refused (Refused) unless the reviewer (a plugin, signoff, register_reviewer) says an
  # approved review exists for the thing's content as it is now. No keyword opens it: the check is the review itself.
  #    The other three statuses and clearing back to none (set!(obj, nil)) are for whoever may change the thing
  #    (may_set?), through change with the optional reason place records.verification. Without a reviewer Verified
  #    cannot be reached and the row says so.
  # 2. "Ändras posten efter granskningen står Verifierad kvar men visas som ändrad sedan granskningen": the stored status
  #    stays; changed_since_review? asks the reviewer when it is shown and nothing is written back.
  # 3. The row on issues of the trackers the administrator chooses (setting verification_tracker_ids), the column and
  #    filter in the issue list, and on records' assessments.
  # 4. Nothing is set when a thing is made.
  # A row whose status was cleared keeps the row with the status none (rows are never deleted, P1); get gives nil.
  module Verification
    STATUSES = %w[verified partly_verified unverified hypothesis].freeze
    # What a person sets by hand; verified only through a review
    MANUAL = %w[partly_verified unverified hypothesis].freeze
    NONE = 'none'
    EVENT = 'verification_changed'
    FEATURE = 'records.verification'
    REASON = 'records.verification'
    # Sorting in the issue list: the surest first, none last
    ORDER = { 'verified' => 1, 'partly_verified' => 2, 'unverified' => 3, 'hypothesis' => 4 }.freeze

    # set!(obj, 'verified') without an approved review for the content as it is now
    class Refused < StandardError; end

    module_function

    def label(status) = status && status.to_s != NONE ? ::I18n.t("label_gk_records_verification_#{status}", default: status.to_s) : ''
    def options = STATUSES.map { |s| [label(s), s] }
    def manual_options = MANUAL.map { |s| [label(s), s] }

    def ready?
      ::GkRecordsVerification.table_exists?
    rescue StandardError
      false
    end

    # On when a tracker has it or a plugin asked for it; off for a new installation (human test records_1021, the
    # owner's choice "Av från början"; GkRecords::Features)
    def feature? = Features.on?('verification')

    # The field's name from the locales (records_1021-SID-56: a name per installation is for a fields plugin later)
    def title = ::I18n.t(:label_gk_records_verification_status)

    # The statuses a reader can meet here: Verifierad only where a plugin reviews (signoff), so that nothing is said
    # about a review where there is none (records_1021: "INTE beskriva sånt som kräver det pluginet")
    def shown_statuses = reviewer ? STATUSES : MANUAL

    def row(obj)
      t = Targets.for_object(obj)
      t && obj&.id ? ::GkRecordsVerification.find_by(target_type: t.key, target_id: obj.id) : nil
    end

    def get(obj)
      s = row(obj)&.status
      s == NONE ? nil : s
    end

    # ------------------------------------------------------------------ the review
    # One plugin reviews (signoff): approved: ->(obj) { the approving signature for the content now, or nil };
    # changed: ->(obj) { true when the content changed after the last approval }; partial: drawn in the row with
    # locals obj and back_url (the request, the signatures, Begär granskning).
    def reviewer = @reviewer

    def register_reviewer(plugin:, approved:, changed:, partial: nil)
      @reviewer = { plugin: plugin.to_s, approved: approved, changed: changed, partial: partial }
    end

    def reviewed?(obj)
      !!(reviewer && reviewer[:approved].call(obj))
    rescue StandardError => e
      Rails.logger.warn("[gk_records] review not asked for #{obj.class.name} #{obj&.id}: #{e.class} #{e.message}")
      false
    end

    # Verified, and the content changed after the approving review: derived when shown, never stored
    def changed_since_review?(obj, status = :ask)
      status = get(obj) if status == :ask
      return false unless status.to_s == 'verified' && reviewer

      reviewer[:changed].call(obj) ? true : false
    rescue StandardError
      false
    end

    # The text the badge and the column show: "Verifierad, ändrad sedan granskningen" when it changed after the review
    def shown_label(obj, status = :ask)
      status = get(obj) if status == :ask
      return '' if status.nil? || status.to_s == NONE

      changed_since_review?(obj, status) ? ::I18n.t(:label_gk_records_verification_changed) : label(status)
    end

    # ------------------------------------------------------------------ the content a review is bound to
    # The text that is hashed for a review: an issue its subject and description; an assessment what it holds (it is
    # never changed); another target what its owner registers, a chosen list of its facts (register_content). A
    # target whose owner says nothing cannot be verified at all: never "all its columns", since a column a plugin
    # adds later would make every review of it stand as changed.
    def contents = (@contents ||= {})
    def register_content(key, fn) = (contents[key.to_s] = fn)

    # The facts as "name=value", in the order given, one per line of the hash
    def facts_text(obj, names) = names.map { |n| "#{n}=#{obj.public_send(n)}" }.join("\u0000")

    def content(obj)
      t = Targets.for_object(obj)
      return contents[t.key].call(obj).to_s if t && contents[t.key]

      case obj
      when ::Issue then "subject=#{obj.subject}\u0000description=#{obj.description}"
      when ::GkRecordsAssessment then [obj.kind, obj.title, obj.outcome, obj.data, obj.basis].map(&:to_s).join("\u0000")
      end
    end

    # May the thing be verified at all: a registered target whose content is chosen
    def verifiable?(obj)
      t = obj && Targets.for_object(obj)
      return false unless t

      contents.key?(t.key) || obj.is_a?(::Issue) || obj.is_a?(::GkRecordsAssessment)
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
    # A person's choice on the page: one of the three, or none; the reason by the place records.verification.
    # [true, nil] or [false, message].
    def change(obj, status, user: ::User.current, reason: nil)
      return [false, ::I18n.t(:error_gk_records_verification_not_here)] unless shown?(obj)
      return [false, ::I18n.t(:error_gk_records_verification_permission)] unless may_set?(obj, user)

      st = status.to_s.presence || NONE
      return [false, ::I18n.t(:error_gk_records_verification_review_only)] if st == 'verified'
      return [false, ::I18n.t(:error_gk_records_verification_unknown)] unless MANUAL.include?(st) || st == NONE

      check = Reasons.check(REASON, reason)
      return [false, check.error] unless check.ok

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
    # clear. nil, '' or none clears it. The event says before and after (nil for none); the reason is a note of kind
    # reason on the thing (Events.write). verified is refused unless the content as it is now has an approved review.
    def set!(obj, status, user: ::User.current, reason: nil, origin: nil)
      status = status.to_s.presence || NONE
      raise ArgumentError, "verification status #{status} is not known" unless STATUSES.include?(status) || status == NONE

      t = Targets.for_object(obj)
      raise ArgumentError, "#{obj.class.name} is not a registered records target" unless t
      raise ArgumentError, "#{obj.class.name}: no content is chosen for a review (register_content)" unless verifiable?(obj)
      raise Refused, ::I18n.t(:error_gk_records_verification_review_only) if status == 'verified' && !reviewed?(obj)

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
        journal!(obj, before, after, reason, who)
        r
      end
    end

    # On an issue the change also stands in its history, as core's own changes do (records_1021-SID-60, the owner's
    # choice "Rad + skälet som anteckning"): a row in Ändrade egenskaper and the reason as the entry's note
    JOURNAL_PROPERTY = 'gk_records'
    JOURNAL_KEY = 'verification'

    def journal!(obj, before, after, reason, who)
      return unless obj.is_a?(::Issue)

      j = ::Journal.new(journalized: obj, user: who || ::User.anonymous, notes: reason.to_s.strip)
      j.details << ::JournalDetail.new(property: JOURNAL_PROPERTY, prop_key: JOURNAL_KEY, old_value: before, value: after)
      j.save!
      j
    end

    # The row in the history: "Verifieringsstatus ändrad från Hypotes till Delvis verifierad", in the reader's language
    module IssuesHelperPatch
      def show_detail(detail, no_html = false, options = {})
        return super unless detail.property == Verification::JOURNAL_PROPERTY && detail.prop_key == Verification::JOURNAL_KEY

        label = Verification.title
        old = Verification.label(detail.old_value).presence
        new = Verification.label(detail.value).presence
        unless no_html
          label = content_tag('strong', label)
          old = content_tag('i', old) if old
          new = content_tag('i', new) if new
        end
        s = if new && old then l(:text_journal_changed, label: label, old: old, new: new).html_safe
            elsif new then l(:text_journal_set_to, label: label, value: new).html_safe
            else l(:text_journal_deleted, label: label, old: no_html ? old : content_tag('del', old)).html_safe
            end
        return s if no_html

        # the mark the page's script finds, so the entry's note is drawn as records' reason (records_1021-SID-71)
        content_tag('span', s, class: 'gk-records-journal-verification', data: { reason_label: l(:label_gk_records_note_reason) })
      end
    end

    # The entry's note beside the row is the reason: records' reason box, indented as the row, with Skäl before it
    # (records_1021-SID-71, the owner's choice "Som records skälruta"); the note stays a note, so Anteckningar has it
    JOURNAL_SCRIPT = <<~JS
      (function () {
        var mark = function () {
          document.querySelectorAll('.journal .gk-records-journal-verification').forEach(function (s) {
            var j = s.closest('.journal'); var w = j && j.querySelector('div.wiki');
            if (!w || w.classList.contains('gk-records-journal-reason') || !w.textContent.trim()) return;
            w.classList.add('gk-records-reason', 'gk-records-journal-reason');
            var b = document.createElement('span'); b.className = 'gk-records-reason-by'; b.textContent = s.getAttribute('data-reason-label');
            w.insertBefore(b, w.firstChild);
          });
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mark); else mark();
        // the history's tabs fetch their content again
        if (window.MutationObserver) new MutationObserver(mark).observe(document.body, { childList: true, subtree: true });
      })();
    JS

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

    module IssueValue
      # The column Verifieringsstatus: the status as text, changed since the review when it is
      def gk_records_verification
        st = instance_variable_defined?(:@gk_records_verification) ? @gk_records_verification : Verification.get(self)
        st ? Verification.shown_label(self, st) : nil
      end
    end

    module IssueQueryPatch
      def issues(options = {})
        list = super
        Verification.preload(list) if Verification.query_column?
        list
      end

      def available_columns
        cols = super
        if Verification.query_column? && cols.none? { |c| c.name == :gk_records_verification }
          order = Verification::ORDER.map { |k, n| "WHEN '#{k}' THEN #{n}" }.join(' ')
          sort = "COALESCE((SELECT CASE v.status #{order} ELSE 5 END FROM #{::GkRecordsVerification.table_name} v " \
                 "WHERE v.target_type = 'issue' AND v.target_id = #{::Issue.table_name}.id), 5)"
          cols << ::QueryColumn.new(:gk_records_verification, caption: -> { Verification.title }, sortable: sort)
        end
        cols
      end

      def initialize_available_filters
        super
        return unless Verification.query_column?

        add_available_filter 'gk_records_verification', type: :list_optional, name: Verification.title,
                                                      values: Verification.shown_statuses.map { |s| [Verification.label(s), s] }
      end

      # = and ! a status among the four, * any status said, !* none (no row, or cleared)
      def sql_for_gk_records_verification_field(_field, operator, value)
        conn = ::GkRecordsVerification.connection
        ids = lambda do |list|
          "#{::Issue.table_name}.id IN (SELECT v.target_id FROM #{::GkRecordsVerification.table_name} v WHERE v.target_type = 'issue' " \
            "AND v.status IN (#{list.map { |s| conn.quote(s) }.join(', ')}))"
        end
        vals = Array(value).map(&:to_s) & Verification::STATUSES
        case operator
        when '=' then vals.empty? ? '1=0' : ids.call(vals)
        when '!' then vals.empty? ? '1=1' : "NOT (#{ids.call(vals)})"
        when '*' then ids.call(Verification::STATUSES)
        when '!*' then "NOT (#{ids.call(Verification::STATUSES)})"
        else '1=0'
        end
      end
    end

    # ------------------------------------------------------------------ the tracker's own page
    # The checkbox Verifieringsstatus on Administration > Trackers, New and Edit (records_1021-SID-28: "det måste ju vara
    # under ärendetyp"). Core's tracker form has no hook, so the box is placed by script and the controller patch keeps
    # the choice in records' setting verification_tracker_ids after the tracker is saved.
    def set_tracker!(tracker_id, on)
      id = tracker_id.to_i
      return false if id.zero? || tracker?(id) == on

      ids = on ? tracker_ids + [id] : tracker_ids - [id]
      now = ::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records.dup : {}
      ::Setting.plugin_gk_records = now.merge('verification_tracker_ids' => ids.map(&:to_s))
      true
    end

    module TrackersControllerPatch
      def create
        super
        Verification.keep_tracker_choice(@tracker, params)
      end

      def update
        super
        Verification.keep_tracker_choice(@tracker, params)
      end
    end

    def keep_tracker_choice(tracker, params)
      return unless tracker&.persisted? && params.key?(:gk_records_verification) && tracker.errors.empty?

      set_tracker!(tracker.id, params[:gk_records_verification].to_s == '1')
    rescue StandardError => e
      Rails.logger.warn("[gk_records] the tracker's verification status not kept: #{e.message}")
    end

    class TrackerHooks < Redmine::Hook::ViewListener
      # on every issue page, also when the row is no longer on for the tracker: earlier entries keep their look
      def view_issues_show_description_bottom(_context = {}) = javascript_tag(JOURNAL_SCRIPT)

      def view_layouts_base_body_bottom(context = {})
        c = context[:controller]
        return '' unless c.is_a?(::TrackersController) && %w[new edit create update].include?(c.action_name) && User.current.admin?

        tracker = c.instance_variable_get(:@tracker)
        on = tracker&.id && Verification.tracker?(tracker.id)
        javascript_tag(<<~JS)
          (function () {
            var form = document.querySelector('form#tracker_form, form.edit_tracker, form.new_tracker');
            var box = form && form.querySelector('.box.tabular');
            if (!box || form.querySelector('[name=gk_records_verification]')) return;
            var p = document.createElement('p');
            var label = document.createElement('label'); label.htmlFor = 'gk_records_verification'; label.textContent = #{Verification.title.to_json};
            var hidden = document.createElement('input'); hidden.type = 'hidden'; hidden.name = 'gk_records_verification'; hidden.value = '0';
            var cb = document.createElement('input'); cb.type = 'checkbox'; cb.name = 'gk_records_verification'; cb.value = '1';
            cb.id = 'gk_records_verification'; cb.checked = #{on ? 'true' : 'false'};
            var em = document.createElement('em'); em.className = 'info'; em.textContent = #{::I18n.t(:text_gk_records_verification_tracker).to_json};
            p.appendChild(label); p.appendChild(hidden); p.appendChild(cb); p.appendChild(em);
            box.appendChild(p);
          })();
        JS
      end
    end

    def apply_patches!
      ::Issue.include(IssueValue) unless ::Issue < IssueValue
      ::IssueQuery.prepend(IssueQueryPatch) unless ::IssueQuery < IssueQueryPatch
      ::TrackersController.prepend(TrackersControllerPatch) unless ::TrackersController < TrackersControllerPatch
      ::IssuesHelper.prepend(IssuesHelperPatch) unless ::IssuesHelper < IssuesHelperPatch
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
