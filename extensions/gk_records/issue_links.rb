# frozen_string_literal: true

module GkRecords
  # Links on the issue page (links_view): the place is a tab in the history row, and a row at the top says how
  # many there are and jumps to the tab. Core builds the tab row in IssuesHelper#issue_history_tabs and has no
  # hook for it (the same in 6.0.11, 6.1.4 and 7.0.1), so the method is extended: a documented core patch. The
  # content is fetched by core's own getRemoteTab from this plugin's controller when the tab is opened;
  # IssuesController is not touched.
  module IssueLinks
    TAB = 'gk_records_links'
    ASSESS_TAB = 'gk_records_assessments'

    # The issue as a target, with the same key and behaviour workflow_rules gave it: events only (its notes are core's
    # journal), seen by whoever may see the issue, linked by whoever may edit it. workflow_rules registers it only when
    # an older records has not.
    def self.register_target!
      ::GkRecords::Targets.register('issue', model: 'Issue',
                                              visible: ->(i, user) { i.visible?(user) }, editable: ->(_i, _user) { false },
                                              label: ->(i) { "#{i.tracker&.name} ##{i.id}: #{i.subject}" },
                                              url: ->(i) { { controller: 'issues', action: 'show', id: i.id } },
                                              # links on an issue (records links_view): whoever may edit the issue
                                              linkable: ->(i, user) { i.attributes_editable?(user) })
    end

    # The tabs say their number (setting tab_counts, off by default; records_1021-SID-19)
    def self.tab_counts? = (::Setting.plugin_gk_records.is_a?(Hash) ? ::Setting.plugin_gk_records['tab_counts'].to_s : '') == '1'

    module HelperPatch
      def issue_history_tabs
        tabs = super
        issue = @issue
        return tabs unless issue && ::GkRecords::Targets.find('issue') && ::GkRecords::Targets.visible?(issue)
        # a tab only while its function is on (records_1021; GkRecords::Features), and only when the issue has links: an
        # issue without one gets the row Lägg till koppling in the issue's actions menu (IssueHooks), which opens the
        # issue with the tab selected, and the tab is there then for one who may link (gui_stuff_1023-SID-41)
        links = ::GkRecords::Features.on?('links') &&
                (::GkRecordsLink.active.touching('issue', issue.id).exists? || (params[:tab].to_s == TAB && ::GkRecords::Targets.linkable?(issue)))
        assessed = ::GkRecords::Features.on?('assessments') && ::GkRecordsAssessment.for_target('issue', issue.id).exists?
        return tabs unless links || assessed

        content_for(:header_tags) { stylesheet_link_tag('gk_records', plugin: 'gk_records') }
        if links
          tabs << { name: TAB, label: :label_gk_records_links, remote: true,
                    onclick: "getRemoteTab('#{TAB}', '#{gk_records_links_tab_path(target: "issue:#{issue.id}")}', '#{issue_path(issue, tab: TAB)}')" }
        end
        # the tab Bedömningar only when the issue has been assessed (assessments are made by rules, not here)
        if assessed
          tabs << { name: ASSESS_TAB, label: :label_gk_records_assessments, remote: true,
                    onclick: "getRemoteTab('#{ASSESS_TAB}', '#{gk_records_assessments_tab_path(target: "issue:#{issue.id}")}', '#{issue_path(issue, tab: ASSESS_TAB)}')" }
        end
        tabs
      rescue StandardError => e
        Rails.logger.warn("[gk_records] links tab not added: #{e.class} #{e.message}")
        tabs || super
      end
    end
  end

  # Nothing at the top of the issue (the owner, human test records_1021-SID-19: "Vi ska inte ha det här alls i ärendens
  # huvud ... flikarna nere räcker"). With the setting tab_counts the tabs Kopplingar and Bedömningar say their
  # number, "Kopplingar (3)": core writes a tab's label from a key, so the number is put after it on the page.
  class IssueHooks < Redmine::Hook::ViewListener
    def view_issues_show_description_bottom(context = {})
      issue = context[:issue]
      return '' unless issue && Targets.find('issue') && Targets.visible?(issue)

      safe_join([add_link_row(issue), tab_counts(issue)].compact)
    end

    # An issue without links has no tab Kopplingar; one who may link gets the row Lägg till koppling in the issue's
    # actions menu (core's actions_dropdown in .contextual, which has no hook), and it opens the issue with the tab
    def add_link_row(issue)
      return nil unless ::GkRecords::Features.on?('links') && Targets.linkable?(issue)
      return nil if ::GkRecordsLink.active.touching('issue', issue.id).exists?

      row = link_to(sprite_icon('link', l(:button_gk_records_link_add)), issue_path(issue, tab: IssueLinks::TAB),
                    class: 'icon icon-link gk-records-link-add')
      javascript_tag(<<~JS)
        (function () {
          var row = #{row.to_json};
          var put = function () {
            document.querySelectorAll('#content > .contextual .drdn-items').forEach(function (items) {
              if (!items.querySelector('.gk-records-link-add')) items.insertAdjacentHTML('afterbegin', row);
            });
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', put); else put();
        })();
      JS
    end

    def tab_counts(issue)
      return nil unless IssueLinks.tab_counts?

      counts = { IssueLinks::TAB => ::GkRecordsLink.active.touching('issue', issue.id).count,
                 IssueLinks::ASSESS_TAB => ::GkRecordsAssessment.for_target('issue', issue.id).count }
      javascript_tag(<<~JS)
        (function () {
          var counts = #{counts.to_json};
          var put = function () {
            Object.keys(counts).forEach(function (name) {
              var a = document.getElementById('tab-' + name);
              if (a && !a.getAttribute('data-gk-count')) { a.setAttribute('data-gk-count', '1'); a.textContent = a.textContent + ' (' + counts[name] + ')'; }
            });
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', put); else put();
        })();
      JS
    end

    # The row Verifieringsstatus among the issue's details, on the trackers the administrator chose
    render_on :view_issues_show_details_bottom, partial: 'gk_records/verification_issue'
  end
end
