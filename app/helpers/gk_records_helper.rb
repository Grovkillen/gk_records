# frozen_string_literal: true

module GkRecordsHelper
  # Light Markdown: core's formatter, then only the light level is kept. Headings become plain text,
  # images and HTML go, tables go; emphasis, code, links, lists, line breaks, mentions and #refs stay.
  LIGHT_TAGS = %w[p br strong em code a ul ol li].freeze

  # Headings, images and rules are taken down in the source first, so core's formatter never makes them (no
  # heading anchors, no image tags); what is left above the level (tables, raw HTML) is stripped after.
  def gk_records_light(text)
    src = text.to_s
               .gsub(/^ {0,3}\#{1,6}[ \t]+(.*?)[ \t#]*$/) { Regexp.last_match(1) }      # ATX heading -> plain line
               .gsub(/^ {0,3}(=+|-{3,}|\*{3,}|_{3,})[ \t]*$/, '')                      # setext underline, rule
               .gsub(/!\[([^\]]*)\]\([^)]*\)/) { Regexp.last_match(1) }                # image -> its alt text
    sanitize(textilizable(src), tags: LIGHT_TAGS, attributes: %w[href class title])
  end

  # A person as core's link, or "en person du inte får se" when the reader may not see her; no person is
  # "systemet", or nothing when system is false. A person shown whom some other user may not see has the mark after
  # the name (gk_records_restricted_mark); on: the thing the name stands on, so the mark counts those who see it.
  def gk_records_user(user, system: true, on: nil)
    unless user
      return system ? gk_records_quiet_word(l(:label_gk_records_by_system)) : ''
    end
    return gk_records_quiet_word(l(:text_gk_records_hidden_person)) unless GkRecords::Visibility.visible_user?(user)

    # a group (a reference in the details may be one) is core's group link where core has it
    name = if user.is_a?(::Group)
             respond_to?(:link_to_principal) ? link_to_principal(user) : h(user.name)
           else
             link_to_user(user)
           end
    # core greys a locked account's name without saying why: the tooltip says it
    name = content_tag('span', name, class: 'gk-records-user-locked', title: l(:text_gk_records_user_locked)) if user.is_a?(::User) && user.locked?
    safe_join([name, gk_records_restricted_mark(user, on: on)])
  end

  # The mark after the name of a person (or group) the reader may see but some other active user may not: GK GUI
  # Stuff's flag in its short form, the pennant in the role warning, the word Begränsad in its small box on hover and
  # for screen readers, and the tip "Syns inte för alla: N personer får inte se den här personen". Never who may not
  # see her. "" when the person is shown to all, hidden from the reader, or the mark is off (setting
  # mark_restricted_people). on: the thing the name stands on (Visibility.hidden_from_count). For other plugins' views
  # as well (people, triggers, workflow_rules).
  def gk_records_restricted_mark(principal, on: nil)
    info = GkRecords::Visibility.restricted_info(principal, on: on)
    info[:restricted] ? gk_records_restricted_mark_count(info[:hidden_from], on: info[:on]) : ''
  end

  # The same mark for a count the caller has (a thing of a registered kind: GkRecords::Ref.thing_restricted_info);
  # "" for nil, 0 or when the mark is off. on: counted among those who see a thing (the text says so). The class
  # gk-records-restricted is the mark's steady anchor for a script that copies it (people's choice of an actor).
  def gk_records_restricted_mark_count(count, on: false)
    return '' unless count.to_i.positive? && GkRecords::Visibility.mark?

    title = GkRecords::Visibility.restricted_title(count, on: on)
    # the flag's short form keeps no title of its own (gk_gui_stuff_flag drops title: with short: true), so the tip
    # stands on the mark around it, and the count is read after the word by a screen reader
    flag = gk_gui_stuff_flag(l(:label_gk_records_restricted_word), inline: true, short: true, role: :warning, title: title)
    content_tag('span', safe_join([flag, content_tag('span', title, class: 'gk-gui-stuff-sr-only')]), class: 'gk-records-restricted', title: title)
  end

  # What stands where a name or a value would have stood ("a thing you may not see", "the system", "a removed
  # person"): GK GUI Stuff's quiet text, soft, in the size of the text around it
  def gk_records_quiet_word(text) = gk_gui_stuff_quiet(text, soft: true, full: true)

  # Under a filter drawn as core's folding Filters: Apply and Clear as core draws them above its lists (links with
  # core's icons). Apply sends the form round it (gk_records.js); a submit button that is not shown keeps Enter in a
  # field sending the form. clear: the list's own address, no Clear without it.
  def gk_records_filter_buttons(clear: nil)
    links = [link_to(sprite_icon('checked', l(:button_apply)), '#', class: 'icon icon-checked', data: { gk_records_submit: '' })]
    links << link_to(sprite_icon('reload', l(:button_clear)), clear, class: 'icon icon-reload') if clear
    safe_join([button_tag('', type: 'submit', name: nil, hidden: true, tabindex: -1, 'aria-hidden': 'true'),
               content_tag(:p, safe_join(links, ' '), class: 'buttons')])
  end

  # Who did it, always said: the person, or "systemet" when no person did (a trigger, a job), never an empty
  # cell; a person the reader may not see is not named
  # on: the event's thing (the mark counts those who see it), found once per event
  def gk_records_who(event)
    thing = gk_records_event_thing(event)
    who = gk_records_user(event.user, on: thing)
    return who unless event.acting_user

    safe_join([who, " (#{l(:text_gk_records_acting, user: GkRecords::Visibility.name_for(event.acting_user))}", gk_records_restricted_mark(event.acting_user, on: thing), ')'])
  end

  def gk_records_event_thing(event)
    (@gk_records_event_things ||= {})[event.id] ||= event.target
  rescue StandardError
    nil
  end

  # The reason with the one who wrote it and when: a reason is a note of its own with its own author, or, on a
  # target whose notes are refused (an issue), the event's details, written by the event's own author
  def gk_records_reason(event)
    n = event.reason_note
    # A system reason in the reader's language as it stood, with the text now beside it when it has changed
    if n
      by, at, body = GkRecords::Visibility.name_for(n.user), n.created_at, n.shown_body
    elsif event.details_reason
      body = event.reason_text
      by, at = GkRecords::Visibility.name_for(event.user), event.created_at
    else
      return ''
    end

    # GK GUI Stuff's shown reason: who wrote it and when on the line at its top
    mark = gk_records_restricted_mark(n ? n.user : event.user, on: gk_records_event_thing(event))
    gk_gui_stuff_reason_shown(safe_join([gk_records_light(body), gk_records_text_now(event.reason_now)]),
                              by: safe_join([l(:text_gk_records_reason_by, user: by, when: format_time(at)), mark]))
  end

  # "nu:..." under a system text whose wording has changed since it was written (SystemText); '' otherwise. GK GUI
  # Stuff's quiet text, soft, on a line of its own
  def gk_records_text_now(now)
    now.present? ? gk_gui_stuff_quiet(l(:text_gk_records_text_now, text: now), soft: true, tag: :div, html: { class: 'gk-records-text-now' }) : ''
  end

  def gk_records_origin_badge(origin)
    return '' if origin.to_s == 'human' || Setting.plugin_gk_records['show_origin_badge'].to_s != '1'

    # what did it when no person did, toned down: GK GUI Stuff's pill, muted
    gk_gui_stuff_pill(l("label_gk_records_origin_#{origin}", default: origin.to_s), muted: true, html: { class: 'gk-records-origin' })
  end

  # An event's kind as GK GUI Stuff's neutral pill
  def gk_records_event_kind_tag(kind)
    gk_gui_stuff_pill(GkRecords::Kinds.label(:event, kind), html: { class: "gk-records-event-kind gk-records-event-kind-#{kind.to_s.tr('.', '-')}" })
  end

  # A note's kind as GK GUI Stuff's pill in the kind's role: a reason notice, a question info, an answer saved, a
  # dispute alarm; a comment and every other kind neutral
  NOTE_KIND_ROLES = { 'reason' => :notice, 'question' => :info, 'answer' => :saved, 'dispute' => :alarm }.freeze

  def gk_records_note_kind_tag(kind)
    gk_gui_stuff_pill(GkRecords::Kinds.label(:note, kind), role: NOTE_KIND_ROLES[kind.to_s], html: { class: "gk-records-kind-#{kind}" })
  end

  # What a row of Läs in dokument would do, as GK GUI Stuff's pill in the status's role: a new document info, a new one
  # though the file is there notice, one that is there already (skipped) muted, a file missing from the zip warning, a
  # row that is not read in alarm, an unknown subproject warning (GkRecords::DocumentImport::STATUSES)
  DOCIMP_ROLES = { 'new' => :info, 'again' => :notice, 'already' => :muted, 'missing' => :warning, 'error' => :alarm,
                   'unknown_project' => :warning }.freeze

  def gk_records_docimp_status(status)
    gk_gui_stuff_pill(l("label_gk_records_docimp_status_#{status}"), role: DOCIMP_ROLES[status.to_s],
                                                                     html: { class: "gk-records-docimp-status gk-records-docimp-status-#{status}" })
  end

  # A thing's verification status as GK GUI Stuff's pill with a dot in the status's role, only to read
  # (no ▾, no box), with who, when and why in its tooltip; Verifierad with the lock after the text, and "ändrad sedan
  # granskningen" as a flag of its own after it. Nothing when no status is said. status: a status already known (a
  # list draws many without a query each).
  def gk_records_verification_badge(obj, status: nil)
    return '' unless defined?(GkRecords::Verification) && ::GkRecordsVerification.table_exists?

    row = status ? nil : GkRecords::Verification.row(obj)
    st = status || row&.status
    return '' if st.nil? || st == GkRecords::Verification::NONE

    v = GkRecords::Verification
    # the words of the thing's place
    place = v.place(obj)
    # who set it, when, and why; a person the reader may not see is not named (Visibility)
    title = nil
    if row
      by = row.set_by_id && ::User.find_by(id: row.set_by_id)
      by = nil if by && !GkRecords::Visibility.visible_user?(by, User.current)
      who = by ? by.name : l(:label_user_anonymous)
      title = [l(:text_gk_records_verification_by, status: v.label(st, place: place), user: who, when: format_time(row.set_at)),
               GkRecords::Verification.reason_text(row)].compact.join("\n")
    end
    verified = st == 'verified' && v.review_locked?(obj)
    pill = gk_gui_stuff_pill(v.label(st, place: place), role: v.role(st), dot: true, title: title,
                             icon_after: verified ? 'lock' : nil, icon_after_label: verified ? l(:text_gk_records_verification_locked) : nil,
                             html: { class: "gk-records-verification gk-records-verification-#{st}" })
    # Verified, but the content changed after the approving review: the stored status stays, and a flag of its own
    # says so until a new review is approved
    return pill unless v.changed_since_review?(obj, st)

    safe_join([pill, gk_gui_stuff_flag(l(:label_gk_records_verification_flag_changed), inline: true, role: :warning,
                                                                                         title: l(:text_gk_records_verification_changed, step: v.label('verified', place: place)))], ' ')
  end

  # Beside a field, the reading that last set it as a link to the reading's page; nothing when no reading set the
  # field.
  # origins: the object's pointers when the page has them already (GkRecords::Readings.origins), so one query serves
  # every field of the page.
  def gk_records_origin(obj, field, origins: nil)
    return '' unless defined?(GkRecords::Readings)

    row = origins ? origins[field.to_s] : nil
    o = row ? { reading: row.reading, source_id: row.source_id, pointer: row } : (origins ? nil : GkRecords::Readings.origin(obj, field))
    return '' unless o && o[:reading]

    text = GkRecords::Readings.label(o[:reading], o[:pointer])
    title = o[:source_id].present? ? l(:text_gk_records_reading_source_id, id: o[:source_id]) : nil
    # GK GUI Stuff's quiet text after the field on its row; the link takes the text's colour, dotted
    gk_gui_stuff_quiet(link_to(text, gk_records_reading_path(o[:reading]), title: title), inline: true, html: { class: 'gk-records-reading-origin' })
  end

  # A reading's counts: "2 tillagda, 1 ändrad, 0 oförändrade, 1 avvisad" (only the four, in that order)
  def gk_records_reading_counts(reading)
    c = reading.counts
    parts = GkRecords::Readings::COUNT_KEYS.filter_map { |k| c.key?(k) ? "#{c[k].to_i} #{l("label_gk_records_reading_count_#{k}")}" : nil }
    parts.join(', ')
  end

  # The row for links on a thing (links_view): the number in force and how many per sort of thing at the other
  # end, as the way to the page (or, on an issue, down to the tab), and a mark for every link of a kind that asks
  # for attention. Nothing when there are none, unless the reader may add one.
  def gk_records_links_row(obj, href: nil)
    tdef = GkRecords::Targets.for_object(obj)
    return '' unless tdef

    sum = GkRecords::Links.summary(tdef.key, obj.id)
    return '' if sum[:total].zero? && !(href.nil? && GkRecords::Targets.linkable?(obj))

    href ||= gk_records_links_page_path(target: "#{tdef.key}:#{obj.id}")
    parts = sum[:by].map { |key, n| "#{GkRecords::Targets.thing_label(key)} #{n}" }
    marks = sum[:attention].map do |k|
      okey, oid, out = GkRecords::Links.other(k, tdef.key, obj.id)
      kind = GkRecords::Kinds.find(:link, k.kind)
      # a kind that asks for attention: GK GUI Stuff's flag in the role warning with the kind's word, then the thing
      flag = gk_gui_stuff_flag(out ? kind.label : (kind.reverse_label || kind.label), inline: true, role: :warning)
      safe_join([flag, gk_records_ref_link(okey, oid)])
    end
    gk_gui_stuff_summary("#{l(:label_gk_records_links)}: #{sum[:total]}", parts, flags: marks, href: href)
  end

  # The row Verifieringsstatus in the records part of a thing without a project of its own (an organization, a person):
  # its status, what may be set, and the review (the reviewer's part: Begär granskning in a project the requester
  # chooses). An issue has its row among the issue's fields and an assessment in its table; a thing with a project is
  # left as it was. Only where the plugin that owns the thing asks for it, so groups, responsibilities, readings and the
  # like keep their records part without it.
  def gk_records_verification_row(obj)
    return '' if obj.is_a?(::Issue) || obj.is_a?(::GkRecordsAssessment)
    return '' if obj.respond_to?(:project) && obj.project
    return '' unless GkRecords::Verification.shown?(obj)

    gk_gui_stuff_summary("#{GkRecords::Verification.title(GkRecords::Verification.place(obj))}:", tag: :div, html: { class: 'gk-records-verification-row' },
                         flags: [render(partial: 'gk_records/verification', locals: { obj: obj, back_url: request.fullpath })])
  end

  # The row for assessments on a thing: how many and the latest outcome, as the way to the page (or, on an issue,
  # down to the tab). Nothing when there are none.
  def gk_records_assessments_row(obj, href: nil)
    tdef = GkRecords::Targets.for_object(obj)
    return '' unless tdef

    sum = GkRecords::Assessments.summary(tdef.key, obj.id)
    return '' if sum[:total].zero?

    href ||= gk_records_assessments_page_path(target: "#{tdef.key}:#{obj.id}")
    a = sum[:latest]
    text = [a.outcome.presence, format_date(User.current.time_to_date(a.assessed_at))].compact.join(', ')
    gk_gui_stuff_summary("#{l(:label_gk_records_assessments)}: #{sum[:total]}", ["#{l(:label_gk_records_latest)}: #{text}"], href: href)
  end

  # A value of an assessment as [label, value] in the reader's language: a custom field's name and a list
  # field's values are translated when fields translations is there and the field still exists; otherwise the
  # label and value as they were frozen
  def gk_records_assess_pair(key, label, value)
    cf = key.to_s =~ /\Acf_(\d+)\z/ && defined?(GkFields::Translations) ? CustomField.find_by(id: Regexp.last_match(1)) : nil
    return [label, value] unless cf && !GkRecords::Ref.any?(value)

    shown = cf.field_format == 'list' ? value.to_s.split(', ').map { |x| GkFields::Translations.value_label(cf, x) }.join(', ') : value
    [cf.name, shown]
  end

  # The row for events on a thing that is not an issue: a count and the way to the thing's own events
  def gk_records_events_row(obj)
    tdef = GkRecords::Targets.for_object(obj)
    return '' unless tdef

    n = GkRecordsEvent.readable_by(User.current).for_target(tdef.key, obj.id).count
    return '' if n.zero?

    gk_gui_stuff_summary("#{l(:label_gk_records_events)}: #{n}", href: gk_records_events_path(target: "#{tdef.key}:#{obj.id}"))
  end

  # What stands in the column for the state of the thing at the other end: an issue's status, nothing for the rest.
  # A closed status as core's closed badge, so a link to a superseded or outdated source (or any closed issue)
  # shows it at a glance. state: what Links.state said, when the caller has asked already (the table's cell asks, since
  # it keeps the badge on one line with its nowrap:)
  def gk_records_other_state(key, id, state = GkRecords::Links.state(key, id))
    return '' unless state
    return state[:text] unless state[:closed]

    content_tag('span', state[:text], class: 'badge badge-status-closed')
  end

  # What a thing cites (Links.citations), one line each as GK GUI Stuff's thing: the kind's word before it, the thing
  # (or the text for one the reader may not see), the place in it, and after it a closed status as core's badge and
  # the thing's verification status, each kept on one line. '' when it cites nothing. For the owner's page beside its
  # own source text.
  def gk_records_citations(obj)
    links = GkRecords::Links.citations(obj)
    return '' if links.empty?

    rows = links.map do |k|
      kind = GkRecords::Kinds.find(:link, k.kind)
      shown = GkRecords::Links.thing(k.target_type, k.target_id)
      s = shown && GkRecords::Links.state(k.target_type, k.target_id)
      after = [s && s[:closed] ? content_tag('span', s[:text], class: 'badge badge-status-closed') : nil,
               shown ? gk_records_verification_badge(shown) : nil]
      gk_gui_stuff_thing(nil, gk_records_ref_link(k.target_type, k.target_id), lead: kind ? kind.label : k.kind,
                         place: shown && k.reason.present? ? k.shown_reason : nil, place_title: l(:label_gk_records_link_locator), after: after)
    end
    content_tag('span', safe_join(rows, tag.br), class: 'gk-records-citations')
  end

  # The list for a target: its notes with the writing box, and the rows for events and links (never lists)
  # verification: true: the owner plugin turns on the row Verifieringsstatus (gk_records_verification_row)
  def gk_records_list(obj, verification: false)
    return '' unless GkRecords::Targets.for_object(obj) && GkRecords::Targets.visible?(obj)

    render partial: 'gk_records/list', locals: { target: obj, verification: verification }
  end

  def gk_records_ref_link(key, id)
    if key.to_s == 'gk_records_note'
      return link_to("#{l(:label_gk_records_note)} ##{id}", "#gk-records-note-#{id}")
    end
    t = GkRecords::Targets.find(key)
    obj = t && t.model_class.find_by(id: id)
    # a thing the reader may not see is a row without a name, so the count holds and no name leaks (links_view)
    return gk_records_quiet_word(l(:text_gk_records_hidden_thing)) unless obj && GkRecords::Targets.visible?(obj)

    # an issue is always core's own issue link: core's link carries the classes tracker-N, status-N and priority-N
    return link_to_issue(obj) if obj.is_a?(::Issue)

    url = GkRecords::Targets.url(obj)
    url ? link_to(GkRecords::Targets.label(obj), url) : GkRecords::Targets.label(obj)
  end

  # A thing of a kind another plugin registered (GkRecords::Ref.register_kind, a register person): its name, a link
  # when the owner gives an address, "en person du inte får se" when the owner says hidden or is not there, and
  # "en borttagen person" when it is gone; the mark after the name when the owner's restricted says some may not see it
  def gk_records_thing(kind, id, found = nil)
    r = GkRecords::Ref.resolve_thing(kind, id, nil, found)
    case r.first
    when :shown then safe_join([r[2] ? link_to(r[1], r[2]) : h(r[1]), gk_records_restricted_mark_count(r[3])])
    when :gone then gk_records_quiet_word(GkRecords::Ref.gone_thing_text)
    else gk_records_quiet_word(l(:text_gk_records_hidden_person))
    end
  end

  # A value in the details: a person referred to (GkRecords::Ref) is core's link to her, "en person du inte får se"
  # or core's name for a principal that is gone; a thing of a registered kind as gk_records_thing; a list of people is
  # them joined with a comma, and a list or hash holding references is shown item by item. Anything else as before.
  # found: the principals, loaded at once. on: the thing the value stands on (an event's thing), for the mark.
  def gk_records_value(v, found = nil, on: nil)
    ref = GkRecords::Ref
    return(v.is_a?(Hash) || v.is_a?(Array) ? v.to_json : v.to_s) unless ref.any?(v)

    found ||= ref.principals(v)
    one = lambda do |id|
      p = found[id]
      p ? gk_records_user(p, on: on) : gk_records_quiet_word(ref.gone_text)
    end
    if ref.one?(v) then one.call(v.values.first)
    elsif ref.many?(v) then safe_join(v.values.first.map { |id| one.call(id) }, ', ')
    elsif ref.thing?(v) then gk_records_thing(ref.at(v, ref::THING), ref.at(v, 'id'), found)
    elsif ref.things?(v) then safe_join(ref.at(v, 'ids').map { |id| gk_records_thing(ref.at(v, ref::THINGS), id, found) }, ', ')
    elsif v.is_a?(Hash) then safe_join(v.map { |k, x| safe_join([k.to_s, ': ', gk_records_value(x, found, on: on)]) }, ', ')
    else safe_join(v.map { |x| gk_records_value(x, found, on: on) }, ', ')
    end
  end

  # An event's changes as GK GUI Stuff's values in the mode changes (from, an arrow, to); '' when there are none.
  # A kind registered with rows: (Kinds.event_rows) gives its own rows in words, the rest are drawn field by field.
  # A private field the reader may not see (GkRecordsEvent#hidden_fields) is named with the text for a hidden value,
  # never its value.
  # fold: true (the events page): a row stays short, the first two entries show and the rest fold
  # in a <details> the reader opens with a click; fewer than two when the first ones are long already (300 characters)
  def gk_records_details(event, fold: false)
    d = event.change_details(User.current)
    hidden = event.hidden_fields(User.current)
    return '' if d.blank? && hidden.empty?

    found = GkRecords::Ref.principals(d)
    # the people in the changes are counted for the mark among those who see the event's thing
    on = gk_records_event_thing(event)
    # each row as the values' primitive takes it: a label with from and to, a label with one value, or a whole row
    v = defined?(GkRecords::Verification) ? GkRecords::Verification : nil
    # a kind whose owner says its changes in words (register_event rows:): its rows, plain texts the values escape;
    # otherwise field by field
    own = defined?(GkRecords::Kinds) && GkRecords::Kinds.respond_to?(:event_rows) ? GkRecords::Kinds.event_rows(event.kind, d, User.current) : nil
    rows = own
    rows ||= d.map do |field, change|
      # A change of the verification status, as the issue's history draws it: "Verifieringsstatus ändrad från
      # <pill> till <pill>", the pills with a dot in their roles; the reason is the event's note
      if v && event.kind == v::EVENT && field.to_s == 'status' && change.is_a?(Array) && change.size == 2
        place = v.place_of(event.target_type, event.target_id)
        pills = change.map { |s| gk_gui_stuff_pill(v.pill_label(s, place: place), role: v.role(s), dot: true) }
        { html: safe_join([content_tag('strong', v.title(place)), ' ', l(:text_gk_records_verification_changed_from_to, old: pills[0], new: pills[1]).html_safe]) }
      elsif GkRecords::Gate.detail?(field, change)
        # written while the gate to GK GUI Stuff was closed: the plugin's name and why, in words
        { label: GkRecords::Gate.label, value: GkRecords::Gate.word(change) }
      elsif change.is_a?(Array) && change.size == 2
        { label: field, from: gk_records_value(change[0], found, on: on), to: gk_records_value(change[1], found, on: on) }
      else
        { label: field, value: gk_records_value(change, found, on: on) }
      end
    end
    rows += hidden.map { |field| { label: field, value: gk_records_quiet_word(l(:text_gk_records_hidden_value)) } }
    list = ->(part) { gk_gui_stuff_values(part, mode: :changes) }
    return list.call(rows) unless fold

    length = ->(r) { strip_tags(r.values.join(' ')).length }
    n = [rows.size, 2].min
    n -= 1 while n > 1 && rows.first(n).sum(&length) > 300
    rest = rows.drop(n)
    return list.call(rows) if rest.empty?

    # the rest in GK GUI Stuff's disclosure, which is the list's last row, drawn without a dot (unmarked): "Visa alla"
    # with the count of all, "Visa färre" when open; the server draws it and it folds without a script
    more = gk_gui_stuff_disclosure(texts: [l(:text_gk_records_show_all), l(:text_gk_records_show_fewer)], count: rows.size,
                                   html: { class: 'gk-records-more' }) { list.call(rest) }
    list.call(rows.first(n) + [{ html: more, unmarked: true }])
  end
  # The shared reason field, kept as a shell for the plugins that still call it: the primitive is GK GUI Stuff's
  # button with a reason (gk_gui_stuff_reason_button), which each caller takes in its next version in place of its own
  # Save and this field. The shell draws GK GUI Stuff's reason (gk_gui_stuff_reason_block): the heading Skäl with the
  # red star, or "valfritt" after it; the text area; the line about the history; the error, hidden until a required
  # reason is missing. Nothing when the place is off and require: is not given; require: true or false overrides the
  # mode for a fixed place whose owner decides (a rule in workflow_rules). The server decides in any case
  # (GkRecords::Reasons.check).
  # Its script is gk_records_reason.js, on every page for a logged-in person (ReasonHooks): a form sent with a required
  # reason left empty, or shorter than the place's least length, is stopped with the error shown and the cursor in the
  # reason; the reason stands on its own line under the form's Save (in a table's cell, after it), never between Save
  # and Cancel; a # in the reason opens core's search for issues; the caller's own label for id: beside the field is
  # hidden, since the block has its heading. The text area gets the caller's id: and every attribute of html:
  # (maxlength, aria-label, a caller's data-*) on the server.
  # size:, area:, rows:, chips:, placeholder: and fold: are taken and not drawn any more: the reason is always the
  # block's open text area, and the earlier reasons are no longer offered (Reasons.suggest_with! is gone).
  def gk_records_reason_field(key, name: 'reason', value: nil, id: nil, size: 30, area: false, rows: 2, chips: false, placeholder: nil,
                              require: nil, fold: nil, html: {})
    r = GkRecords::Reasons
    mode = r.mode(key)
    return ''.html_safe if mode == 'off' && require.nil?

    need = require.nil? ? mode == 'required' : (require ? true : false)
    place = r.find(key)
    # a block id of its own per field: a counter on the view would start again in every render, also in a form fetched
    # into a page that already has a block
    block_id = "gk-records-reason-#{SecureRandom.hex(4)}"
    data = { gk_records_reason: key.to_s, gk_records_reason_need: need ? '1' : '0',
             gk_records_reason_min: need && place&.min ? place.min : nil }.compact
    # the text area takes the caller's id (the block's label follows it) and every attribute of html:, given to the block
    # on the server so that a caller's script finds them whatever order the scripts run in
    block = gk_gui_stuff_reason_block(required: need, id: block_id, name: name, value: value, area_id: id.presence&.to_s,
                                      area: html.to_h.transform_keys(&:to_s).except('id', 'name'))
    content_tag('span', block, class: 'gk-records-reason-wrap', data: data)
  end
end
