# frozen_string_literal: true

module GkRecords
  # A setting's or a function's footprint: where on Redmine's pages it changes something, declared as data by the plugin
  # that registers it (AppearanceSettings.register and Features.register take footprint: and applies:), so that the
  # settings pages can say what each row affects, and so that what marks a change on a page finds it by a stable anchor
  # and never by text, look, position or a guessed nesting. Plain Ruby without Rails: the pipeline's footprint check and
  # the plugins' tests read this file as it is.
  #   footprint: { anchors: ['.gk-gui-stuff-instance'], elements: %w[top_band], pages: %w[all],
  #                adds: [{ anchor: '#main-menu .gk-tags-marks', label: :label_gk_tags_marks }], removes: ['#footer'] }
  #   applies: :server   (or a list: %i[server script])
  # The parts:
  # * anchors: CSS selectors of what the setting changes. Only stable anchors (ANCHOR rules below): a compound part of a
  #   selector carries only GK's own classes, ids or data attributes (.gk-, #gk-, [data-gk), core's purposeful classes,
  #   ids and data attributes in the named lists below (and GK Core Stuff's marks, which are core candidates), and may
  #   name its tag besides; never a pseudo class, a child or sibling combinator, a bare tag, * or a guessed attribute
  #   value. The parts are joined only by the descendant combinator (a space).
  # * elements: keys of the style guide's elements the setting changes (GK GUI Stuff's style guide: core_badges,
  #   core_tables, top_band ...), so that a picture of the change can be drawn from the style guide's examples.
  # * pages: the page types the setting shows on, or 'all'. A page type is a key of the form <owner>.<name>, such as
  #   core.issue or gui_stuff.styleguide, kept as text.
  # * adds and removes: what appears or disappears with the setting or the function (a menu row, a tab, a button, a
  #   column, something hidden), each an anchor as above, or { anchor:, label: } with a locale key that names it.
  # applies says how the change reaches the page: class (a class or a custom property already on every page, so it can
  # change at once), server (the server draws it), script (a stylesheet or a script loaded only while it is on), data (a
  # permission or what is stored); none for a setting without any visible effect. A setting with a visible effect needs a
  # footprint; one that has none shows "not described yet" and is never guessed.
  # What a module draws or styles itself carries the effect mark data-gk-<plugin>-effect="<name>" (effect_attribute),
  # which counts as an anchor of that setting without being listed.
  module Footprint
    PARTS = %w[anchors elements pages adds removes].freeze
    LISTED = %w[adds removes].freeze
    APPLIES = %w[class server script data none].freeze
    ALL_PAGES = 'all'
    PAGE = /\A(?:all|[a-z0-9_]+\.[a-z0-9_.]+)\z/
    ELEMENT = /\A[a-z0-9_]+\z/

    # GK's own anchors: a class, an id or a data attribute of a GK plugin
    OWN_CLASS = 'gk-'
    OWN_ID = 'gk-'
    OWN_ATTRIBUTE = 'data-gk'
    # Core's purposeful ids: what core's layout and views give an id to name the thing itself
    CORE_IDS = %w[account admin-menu content context-menu flash_error flash_notice footer gantt_area gantt_draw_area header
                  history issue-form issue_description_edit_link issue_tree loggedas main main-menu query_form quick-search
                  relations sidebar top-menu update watchers wrapper].freeze
    # Core's purposeful classes: what core's views and helpers set to name what an element is
    CORE_CLASSES = %w[attachments attributes autoscroll badge box breadcrumbs checkbox contextual copy-pre-content-link
                      current-project description details disabled dropdown dropdown-content error flash folder
                      gantt_selected_column gantt_subjects_column help icon info issue issues journal journal-info list
                      members more-attributes nodata notice overdue pagination pre-wrapper private-notes short_description
                      splitcontent subject submenu tabs tabular warning wiki].freeze
    # GK Core Stuff's class marks on core's views (core candidates): anchor_marks' (site-title, issue-heading,
    # subject-heading, current-status, field-name and the version control table's scm_ columns) and section_marks'
    # section-heading
    CORE_STUFF_CLASSES = %w[current-status field-name issue-heading scm_command scm_name scm_path scm_version section-heading
                            site-title subject-heading].freeze
    # Families of core's purposeful classes, one per thing: an icon's name (icon-time-add) and a custom field's id (cf_ and the id)
    CORE_CLASS_PREFIXES = %w[icon- cf_].freeze
    # Core's data attributes, and GK Core Stuff's marks on core's views (written as core candidates)
    CORE_ATTRIBUTES = %w[data-attachment-id data-field data-form-action data-menu data-menu-item data-principal-id data-project
                         data-query-action data-query-part data-report-column data-section data-section-action data-status-closed
                         data-status-id].freeze
    # The attribute operators an anchor may use: presence, an exact value and one word of a list
    OPERATORS = ['', '=', '~='].freeze

    module_function

    # The footprint as kept: string keys, each part a frozen list; adds and removes as { 'anchor' =>, 'label' => }.
    # nil for none. An unknown part or a part of the wrong form raises ArgumentError.
    def normalize(footprint, key = nil)
      return nil if footprint.nil?
      raise ArgumentError, "#{key}: footprint is a hash" unless footprint.is_a?(Hash)

      out = {}
      footprint.each do |part, list|
        p = part.to_s
        raise ArgumentError, "#{key}: footprint has no part #{p}" unless PARTS.include?(p)

        out[p] = LISTED.include?(p) ? listed(list, key, p) : plain(list, key, p)
      end
      out.freeze
    end

    def plain(list, key, part)
      items = Array(list).map(&:to_s)
      pattern = { 'elements' => ELEMENT, 'pages' => PAGE }[part]
      bad = pattern ? items.reject { |i| i.match?(pattern) } : items.select { |i| i.strip.empty? }
      raise ArgumentError, "#{key}: footprint #{part} #{bad.join(', ')}" if bad.any?

      items.uniq.freeze
    end

    def listed(list, key, part)
      Array(list).map do |e|
        h = e.is_a?(Hash) ? e.transform_keys(&:to_s) : { 'anchor' => e }
        raise ArgumentError, "#{key}: footprint #{part} needs an anchor" if h['anchor'].to_s.strip.empty?
        raise ArgumentError, "#{key}: footprint #{part} has #{(h.keys - %w[anchor label]).join(', ')}" unless (h.keys - %w[anchor label]).empty?

        { 'anchor' => h['anchor'].to_s, 'label' => h['label']&.to_s }.freeze
      end.freeze
    end

    # applies as kept: a frozen list of words; [] when nothing was said. A word outside APPLIES, or none together with
    # another word, raises ArgumentError.
    def applies(value, key = nil)
      words = Array(value).map(&:to_s).uniq
      bad = words - APPLIES
      raise ArgumentError, "#{key}: applies #{bad.join(', ')}" if bad.any?
      raise ArgumentError, "#{key}: applies none with #{(words - ['none']).join(', ')}" if words.include?('none') && words.size > 1

      words.freeze
    end

    # Whether the setting has a visible effect by its applies: said, and not none
    def visible?(applies) = Array(applies).any? && Array(applies) != ['none']

    # Whether a footprint says anything at all
    def described?(footprint) = footprint.is_a?(Hash) && footprint.values.any? { |v| Array(v).any? }

    # Every anchor of a footprint: its anchors, then the anchors of what it adds and removes
    def anchors_of(footprint)
      return [] unless footprint.is_a?(Hash)

      Array(footprint['anchors']) + LISTED.flat_map { |p| Array(footprint[p]).map { |e| e['anchor'] } }
    end

    # The anchors that do not keep to the rules, with the reason: [[anchor, reason], ...]
    def problems(footprint) = anchors_of(footprint).filter_map { |a| (r = anchor_problem(a)) ? [a, r] : nil }

    # The footprint without the anchors that break the rules (what a page's marking may use)
    def stable(footprint)
      return footprint unless footprint.is_a?(Hash)

      out = footprint.dup
      out['anchors'] = Array(footprint['anchors']).reject { |a| anchor_problem(a) }.freeze if footprint.key?('anchors')
      LISTED.each { |p| out[p] = Array(footprint[p]).reject { |e| anchor_problem(e['anchor']) }.freeze if footprint.key?(p) }
      out.freeze
    end

    # Why an anchor breaks the rules, or nil when it keeps to them. Each selector of a list is read on its own; a part is
    # a compound selector between descendant combinators.
    def anchor_problem(selector)
      s = selector.to_s.strip
      return 'empty' if s.empty?

      split_top(s, ',').each do |one|
        return 'empty' if one.strip.empty?

        parts = compounds(one)
        return parts if parts.is_a?(String)

        parts.each do |c|
          r = compound_problem(c)
          return "#{r}: #{c}" if r
        end
      end
      nil
    end

    # The compound selectors of one selector, joined by the descendant combinator, or the reason it breaks the rules (a
    # child or a sibling combinator: a guessed nesting)
    def compounds(selector)
      out = []
      cur = +''
      depth = 0
      quote = nil
      selector.each_char do |ch|
        if quote
          cur << ch
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
          cur << ch
        elsif ch == '[' || ch == '('
          depth += 1
          cur << ch
        elsif ch == ']' || ch == ')'
          depth -= 1
          cur << ch
        elsif depth.zero? && (ch == '+' || ch == '~')
          return 'sibling combinator'
        elsif depth.zero? && ch == '>'
          return 'child combinator'
        elsif depth.zero? && ch.match?(/\s/)
          out << cur unless cur.empty?
          cur = +''
        else
          cur << ch
        end
      end
      out << cur unless cur.empty?
      out
    end

    # Why a compound selector breaks the rules, or nil
    def compound_problem(compound)
      c = compound.dup
      outside = c.gsub(/\[[^\]]*\]/, '[]') # what stands outside the attribute selectors
      return 'pseudo class' if outside.include?(':')
      return 'universal selector' if outside.include?('*')

      c = c.sub(/\A[a-z][a-z0-9-]*/, '') # the tag, allowed beside an anchor
      return 'bare tag' if c.empty?

      count = 0
      until c.empty?
        case c
        when /\A\.(-?[_a-zA-Z][\w-]*)/
          return "class .#{Regexp.last_match(1)}" unless own_or_core_class?(Regexp.last_match(1))
        when /\A#(-?[_a-zA-Z][\w-]*)/
          return "id ##{Regexp.last_match(1)}" unless own_or_core_id?(Regexp.last_match(1))
        when /\A\[\s*([a-zA-Z_][\w-]*)\s*(?:([~|^$*]?=)\s*("[^"]*"|'[^']*'|[\w-]+)\s*)?\]/
          name = Regexp.last_match(1)
          op = Regexp.last_match(2).to_s
          return "attribute #{name}" unless own_or_core_attribute?(name)
          return "operator #{op}" unless OPERATORS.include?(op)
        else
          return 'unreadable'
        end
        count += 1
        c = Regexp.last_match.post_match
      end
      count.zero? ? 'bare tag' : nil
    end

    def own_or_core_class?(name)
      name.start_with?(OWN_CLASS) || CORE_CLASSES.include?(name) || CORE_STUFF_CLASSES.include?(name) ||
        CORE_CLASS_PREFIXES.any? { |p| name.start_with?(p) && name.size > p.size }
    end
    def own_or_core_id?(name) = name.start_with?(OWN_ID) || CORE_IDS.include?(name)
    def own_or_core_attribute?(name) = name.start_with?(OWN_ATTRIBUTE) || CORE_ATTRIBUTES.include?(name)

    # A text split at a character outside brackets, parentheses and quotes
    def split_top(text, sep)
      out = [+'']
      depth = 0
      quote = nil
      text.each_char do |ch|
        if quote
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
        elsif '[('.include?(ch)
          depth += 1
        elsif '])'.include?(ch)
          depth -= 1
        elsif ch == sep && depth.zero?
          out << +''
          next
        end
        out.last << ch
      end
      out
    end

    # The effect mark of a plugin's own elements: data-gk-gui-stuff-effect for gui_stuff.<name> or gk_gui_stuff
    def effect_attribute(owner)
      o = owner.to_s.sub(/\Agk_/, '').split('.').first.to_s
      "data-gk-#{o.tr('_', '-')}-effect"
    end

    # The mark's value for a key: the name after the plugin (gui_stuff.filled_badges gives filled_badges)
    def effect_name(key) = key.to_s.split('.', 2).last.to_s

    # The selector that finds what a module drew or styled for the setting: [data-gk-gui-stuff-effect~="filled_badges"]
    def effect_selector(key) = %([#{effect_attribute(key)}~="#{effect_name(key)}"])
  end
end
