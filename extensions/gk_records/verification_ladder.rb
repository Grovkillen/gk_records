# frozen_string_literal: true

module GkRecords
  module Verification
    # The one ladder of verification steps, the same on every place, with fixed keys that rules, filters and exports
    # build on. No plugin and no administrator can add, remove or reorder a step; a place only chooses which of the
    # optional levels are on, the words and the row's name.
    LADDER = %w[none hypothesis unverified partly_verified verified].freeze
    # On every place
    FORCED = %w[none unverified verified].freeze
    # Chosen per place
    OPTIONAL = %w[hypothesis partly_verified].freeze
    # The stored statuses (none is a row that was cleared)
    STATUSES = (LADDER - %w[none]).freeze

    # The pure rules of the ladder and of a place's stored choices; no Rails, no database (unit tested)
    module Ladder
      module_function

      # The steps of list in the ladder's order, unknown keys left out
      def ordered(list)
        keys = Array(list).map(&:to_s)
        LADDER.select { |s| keys.include?(s) }
      end

      # The optional levels that are on: the place's own choice, else the base's (an issue's tracker falls back to the
      # issue default), else the registered default. nil means "not chosen".
      def chosen_optional(own, base, default)
        pick = [own, base].detect { |v| !v.nil? }
        pick = default.nil? ? OPTIONAL : default if pick.nil?
        OPTIONAL & Array(pick).map(&:to_s)
      end

      # The forced levels, the chosen optional ones and an optional one that is off but still has records there
      def levels(chosen, used = [])
        ordered(FORCED + Array(chosen) + (OPTIONAL & Array(used).map(&:to_s)))
      end

      # The steps chosen by hand in the box: every level, verified only where the place does not lock it to the review
      def hand_steps(levels, locked) = locked ? levels - ['verified'] : levels

      # Where the records of a level that is switched off may go: the other levels, verified only where the place
      # does not lock it to the review
      def move_targets(levels, level, locked)
        out = levels - [level.to_s]
        locked ? out - ['verified'] : out
      end

      # The target pressed first in the move box: unverified, which is on everywhere
      def default_target(targets) = targets.include?('unverified') ? 'unverified' : targets.first

      # Why a step cannot be chosen by hand here, or nil: :unknown, :review_only or :level_off
      def refusal(step, levels, locked)
        st = step.to_s.presence || 'none'
        return :unknown unless LADDER.include?(st)
        return :review_only if st == 'verified' && locked
        return :level_off unless levels.include?(st)

        nil
      end

      # Whether "ändrad sedan granskningen" is asked at all: verified, on a place that sets it through the review
      def review_flag?(status, locked) = status.to_s == 'verified' && locked ? true : false

      # Whether the row's pill opens its box: for whoever may change the status; for a reader only on verified with a
      # review part that has something to show (the place sets verified through the review, or a review is still open)
      def opens?(may:, verified:, partial:, locked:, open:)
        return true if may

        verified && partial && (locked || open) ? true : false
      end

      # A level's state in a place's box: :forced (always on), :on (chosen), :kept (off, but records there still have
      # it, until they are moved) or :off
      def level_state(step, levels, chosen)
        s = step.to_s
        return :forced if FORCED.include?(s)
        return :on if Array(chosen).map(&:to_s).include?(s)

        Array(levels).map(&:to_s).include?(s) ? :kept : :off
      end

      # A hash with string keys from a Hash or request parameters; anything else is {}
      def hashify(value)
        h = if value.respond_to?(:to_unsafe_h) then value.to_unsafe_h
            elsif value.is_a?(Hash) then value
            else {}
            end
        h.to_h.transform_keys(&:to_s)
      end

      # The value a ticked check box of a level that is off but kept by its records sends: "leave it as it is"
      KEPT = 'kept'

      # One place's levels as its settings form posts them (gk_records_vlevels[<place>]): per optional step a hidden 0
      # and the check box's 1 (on) or kept (off, kept by its records, left as it is), and from the move box
      # move[<step>] (the level its records go to) and reason[<step>]. A step that is not posted is left as it is.
      # { 'on' => [...], 'off' => [...], 'kept' => [...], 'move' => { step => level }, 'reason' => { step => text } }
      def posted_levels(value)
        h = hashify(value)
        out = { 'on' => [], 'off' => [], 'kept' => [], 'move' => {}, 'reason' => {} }
        OPTIONAL.each do |s|
          next unless h.key?(s)

          bucket = case h[s].to_s
                   when '1' then 'on'
                   when KEPT then 'kept'
                   else 'off'
                   end
          out[bucket] << s
        end
        move = hashify(h['move'])
        reason = hashify(h['reason'])
        OPTIONAL.each do |s|
          m = move[s].to_s.strip
          r = reason[s].to_s.strip
          out['move'][s] = m unless m.empty?
          out['reason'][s] = r unless r.empty?
        end
        out
      end

      # What saving a place's posted levels does, decided before anything is saved. chosen: the optional levels on
      # now; levels: the place's levels now (with one kept by its records); counts: { step => records there } for the
      # steps posted off; locked: verified only through the review.
      # { 'optional' => the optional levels on after the save, 'write' => whether that differs from chosen,
      #   'moves' => { step => { 'to' => level, 'reason' => text or nil, 'count' => n } } for each level switched off
      #   that has records, 'errors' => [[step, :target or :reason_missing]] }
      # A level switched off with records needs a level that stays (verified only where the place does not lock it to
      # the review); the reason is only said to be missing here, the reason's place decides whether it may be.
      def level_plan(posted, chosen:, levels:, counts:, locked:)
        posted ||= posted_levels({})
        now = ordered(OPTIONAL & Array(chosen).map(&:to_s))
        off = Array(posted['off'])
        after = ordered((now - off) | Array(posted['on']))
        with_records = OPTIONAL.select { |s| counts.to_h[s].to_i.positive? }
        # what is there after the save: the forced levels, the chosen ones, and a kept one that is not switched off
        stay = ordered(FORCED + after + ((OPTIONAL & Array(levels).map(&:to_s)) - off))
        moves = {}
        errors = []
        (off & with_records).each do |s|
          to = posted['move'].to_h[s].to_s
          reason = posted['reason'].to_h[s].to_s.strip
          errors << [s, :target] unless move_targets(stay, s, locked).include?(to)
          errors << [s, :reason_missing] if reason.empty?
          moves[s] = { 'to' => to, 'reason' => reason.empty? ? nil : reason, 'count' => counts.to_h[s].to_i }
        end
        { 'optional' => after, 'write' => after != now, 'moves' => moves, 'errors' => errors }
      end

      # Whether a plan changes anything
      def plan_changes?(plan) = plan.is_a?(Hash) && (plan['write'] || plan['moves'].to_h.any?) ? true : false

      # A change of the status as one line of text: "Verifieringsstatus: Hypotes > Delvis verifierad"
      def change_line(title, before, after, sep = '>') = "#{title}: #{before} #{sep} #{after}"

      # A place's own word in a language from { lang => text }, or nil
      def word(texts, lang)
        return nil unless texts.is_a?(Hash)

        t = texts[lang.to_s] || texts[lang.to_s.to_sym]
        t = t.to_s.strip
        t.empty? ? nil : t
      end

      # { lang => text } trimmed, the empty ones left out
      def texts(value)
        return {} unless value.is_a?(Hash)

        value.to_h.each_with_object({}) do |(l, t), h|
          k = l.to_s.strip
          v = t.to_s.strip
          h[k] = v unless k.empty? || v.empty?
        end
      end

      # A place's stored choices in one shape: 'optional' only when chosen (an empty list is a choice), 'title' and
      # 'words' per language, words only for the ladder's steps
      def clean_place(value)
        h = value.is_a?(Hash) ? value.to_h.transform_keys(&:to_s) : {}
        out = {}
        out['optional'] = OPTIONAL & Array(h['optional']).map(&:to_s) if h.key?('optional')
        title = texts(h['title'])
        out['title'] = title unless title.empty?
        words = (h['words'].is_a?(Hash) ? h['words'].to_h : {}).each_with_object({}) do |(s, t), w|
          next unless LADDER.include?(s.to_s)

          tx = texts(t)
          w[s.to_s] = tx unless tx.empty?
        end
        out['words'] = words unless words.empty?
        out
      end

      # Every place's stored choices, cleaned; a place left with nothing is dropped
      def clean_places(value)
        return {} unless value.is_a?(Hash)

        value.to_h.each_with_object({}) do |(k, v), h|
          c = clean_place(v)
          h[k.to_s] = c unless k.to_s.strip.empty? || c.empty?
        end
      end

      # The tracker an issue list is locked to: the filter tracker_id with = and one value, else nil
      def list_tracker(filters)
        f = filters.is_a?(Hash) ? (filters['tracker_id'] || filters[:tracker_id]) : nil
        return nil unless f.is_a?(Hash)

        op = f[:operator] || f['operator']
        vals = Array(f[:values] || f['values']).map(&:to_s).reject(&:empty?)
        op.to_s == '=' && vals.size == 1 && vals.first.match?(/\A\d+\z/) ? vals.first.to_i : nil
      end

      # A tracker's place key, and the tracker id of a place key (nil for any other place)
      def tracker_place(id) = "issue:#{id.to_i}"
      def tracker_of(place) = (m = place.to_s.match(/\Aissue:(\d+)\z/)) ? m[1].to_i : nil

      # The place a place's words and levels fall back to: an issue's tracker to the issue default
      def base(place) = tracker_of(place) ? 'issue' : place.to_s

      # The review rule a place registered: :always, :never, or a callable with the thing; nil thing for the place
      def locked?(rule, obj = nil)
        case rule
        when nil, :always, true, 'always' then true
        when :never, false, 'never' then false
        else rule.respond_to?(:call) ? (rule.call(obj) ? true : false) : true
        end
      rescue StandardError
        true
      end
    end
  end
end
