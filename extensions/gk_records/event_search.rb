# frozen_string_literal: true

module GkRecords
  # The free text search of the event log (parameter q on the page, in its CSV and through the API, also on a project's
  # tab). It looks in what the reader is shown of an event and in nothing else: the kind's name, the target's name (a
  # target the reader may not see is not named), the people she may see, the changes (GkRecordsEvent#changes_text, without
  # private fields, and with people she may not see as the neutral text) and the reason. So a search can never tell what
  # change_details and GkRecords::Visibility keep from her, which a LIKE on the stored details would. Most of these are
  # worked out in code (the target's name, a text in the reader's language), so the search goes through the events newest
  # first, after the other filters, until it has enough; at most MAX_SEEN events in one search, and the page says when it
  # stopped there.
  module EventSearch
    BATCH = 500
    MAX_SEEN = 10_000
    MAX_WORDS = 10

    Found = Struct.new(:events, :cut, keyword_init: true)

    module_function

    # The words of a search, in the case they are compared in; every word must be found. Nothing for a value that is
    # no text (q[]=, q[a]=)
    def words(query)
      return [] unless query.is_a?(String)

      query.downcase.split.first(MAX_WORDS)
    end

    # What the reader is shown of the event, as one text
    def text_of(event, viewer = User.current)
      person = ->(u) { u && Visibility.visible_user?(u, viewer) ? u.name : nil }
      note = event.reason_note
      parts = [event.kind_label, event.target_label(viewer), event.changes_text(viewer), event.reason_text, event.reason_now,
               person.call(event.user), person.call(event.acting_user), note && person.call(note.user)]
      parts << Visibility.name_for(nil, viewer) if event.user.nil?
      parts.compact.join("\n").downcase
    end

    def hit?(event, words, viewer = User.current)
      text = text_of(event, viewer)
      words.all? { |w| text.include?(w) }
    end

    # The first limit events of scope (ordered, newest first) with every word
    def search(scope, words, limit:, viewer: User.current)
      found = []
      seen = 0
      rows = scope.includes(:acting_user, reason_note: :user)
      while seen < MAX_SEEN && found.size < limit
        batch = rows.offset(seen).limit(BATCH).to_a
        break if batch.empty?

        load_targets(batch)
        batch.each do |event|
          seen += 1
          found << event if hit?(event, words, viewer)
          break if found.size >= limit
        end
        break if batch.size < BATCH
      end
      Found.new(events: found, cut: found.size < limit && seen >= MAX_SEEN && rows.offset(seen).exists?)
    end

    # The batch's targets with one query per kind of target, not one per event
    def load_targets(events)
      events.group_by(&:target_type).each do |key, list|
        t = Targets.find(key)
        next unless t

        objects = t.model_class.where(id: list.map(&:target_id).uniq).index_by(&:id)
        list.each { |e| e.target_known(objects[e.target_id]) }
      end
    end
  end
end
