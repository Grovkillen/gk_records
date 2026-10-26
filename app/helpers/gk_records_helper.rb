# frozen_string_literal: true

module GkRecordsHelper
  # Light Markdown (5.6c): core's formatter, then only the light level is kept. Headings become plain text,
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
      return system ? content_tag('span', l(:label_gk_records_by_system), class: 'gk-records-system') : ''
    end
    return content_tag('span', l(:text_gk_records_hidden_person), class: 'gk-records-hidden') unless GkRecords::Visibility.visible_user?(user)

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

  # The mark after the name of a person (or group) the reader may see but some other active user may not: an icon
  # with the text "Syns inte för alla: N personer får inte se den här personen" on hover and for screen readers.
  # Never who may not see her. "" when the person is shown to all, hidden from the reader, or the mark is off
  # (setting mark_restricted_people). on: the thing the name stands on (Visibility.hidden_from_count). For other
  # plugins' views as well.
  def gk_records_restricted_mark(principal, on: nil)
    info = GkRecords::Visibility.restricted_info(principal, on: on)
    info[:restricted] ? gk_records_restricted_mark_count(info[:hidden_from], on: info[:on]) : ''
  end

  # The same mark for a count the caller has (a thing of a registered kind: GkRecords::Ref.thing_restricted_info);
  # "" for nil, 0 or when the mark is off. on: counted among those who see a thing (the text says so)
  def gk_records_restricted_mark_count(count, on: false)
    return '' unless count.to_i.positive? && GkRecords::Visibility.mark?

    gk_records_restricted_assets
    title = GkRecords::Visibility.restricted_title(count, on: on)
    content_tag('span', gk_records_restricted_icon, class: 'gk-records-restricted', title: title, role: 'img', 'aria-label': title)
  end

  # The icon: eye-off from gk_icons (core's own when core has it), otherwise core's lock; never a character alone.
  # Core's size class is kept so the icon has a size even where records' stylesheet is not on the page.
  def gk_records_restricted_icon
    if respond_to?(:gk_icon) && defined?(::GkIcons) && ::GkIcons.exists?('eye-off')
      gk_icon('eye-off')
    elsif respond_to?(:sprite_icon)
      sprite_icon('lock')
    else
      content_tag('span', l(:label_gk_records_restricted_short), class: 'gk-records-restricted-text')
    end
  end

  # records' stylesheet once on a page of another plugin that shows the mark
  def gk_records_restricted_assets
    return if @gk_records_restricted_assets

    @gk_records_restricted_assets = true
    content_for(:header_tags) { stylesheet_link_tag('gk_records', plugin: 'gk_records') }
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

    mark = gk_records_restricted_mark(n ? n.user : event.user, on: gk_records_event_thing(event))
    content_tag('div', safe_join([content_tag('span', safe_join([l(:text_gk_records_reason_by, user: by, when: format_time(at)), mark]), class: 'gk-records-reason-by'),
                                    gk_records_light(body), gk_records_text_now(event.reason_now)]), class: 'gk-records-reason')
  end

  # "nu:..." under a system text whose wording has changed since it was written (SystemText); '' otherwise
  def gk_records_text_now(now)
    now.present? ? content_tag('div', l(:text_gk_records_text_now, text: now), class: 'gk-records-meta gk-records-text-now') : ''
  end

  def gk_records_origin_badge(origin)
    return '' if origin.to_s == 'human' || Setting.plugin_gk_records['show_origin_badge'].to_s != '1'

    content_tag('span', l("label_gk_records_origin_#{origin}", default: origin.to_s), class: 'gk-records-origin')
  end

  def gk_records_event_kind_tag(kind)
    content_tag('span', GkRecords::Kinds.label(:event, kind), class: "gk-records-kindtag gk-records-event-kind gk-records-event-kind-#{kind.to_s.tr('.', '-')}")
  end

  # A thing's verification status as core's badge, with when and why in the title (who set it is in the event, named
  # there by records' rules); nothing when no status is said. status: a status already known (a list draws many
  # without a query each).
  VERIFICATION_BADGES = { 'verified' => 'badge-status-closed', 'partly_verified' => 'badge-status-open',
                          'unverified' => 'badge-private', 'hypothesis' => 'badge-status-locked' }.freeze

  def gk_records_verification_badge(obj, status: nil)
    return '' unless defined?(GkRecords::Verification) && ::GkRecordsVerification.table_exists?

    row = status ? nil : GkRecords::Verification.row(obj)
    st = status || row&.status
    return '' if st.nil? || st == GkRecords::Verification::NONE

    # who set it, when, and why (records_1021-SID-41); a person the reader may not see is not named (Visibility)
    title = nil
    if row
      by = row.set_by_id && ::User.find_by(id: row.set_by_id)
      by = nil if by && !GkRecords::Visibility.visible_user?(by, User.current)
      who = by ? by.name : l(:label_user_anonymous)
      title = [l(:text_gk_records_verification_by, status: GkRecords::Verification.label(st), user: who, when: format_time(row.set_at)),
               GkRecords::Verification.reason_text(row)].compact.join("\n")
    end
    # Verified, but the content changed after the approving review: the stored status stays, shown in a style of its
    # own until a new review is approved
    if GkRecords::Verification.changed_since_review?(obj, st)
      return content_tag('span', l(:label_gk_records_verification_changed), class: 'badge badge-status-closed gk-records-verification gk-records-verification-changed',
                                                                          title: [title, l(:text_gk_records_verification_changed)].compact.join(': '))
    end

    content_tag('span', GkRecords::Verification.label(st), class: "badge #{VERIFICATION_BADGES[st]} gk-records-verification gk-records-verification-#{st}", title: title)
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
    content_tag('span', link_to(text, gk_records_reading_path(o[:reading]), title: title), class: 'gk-records-reading-origin')
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
  def gk_records_links_row(obj, href: nil, onclick: nil)
    tdef = GkRecords::Targets.for_object(obj)
    return '' unless tdef

    sum = GkRecords::Links.summary(tdef.key, obj.id)
    return '' if sum[:total].zero? && !(href.nil? && GkRecords::Targets.linkable?(obj))

    href ||= gk_records_links_page_path(target: "#{tdef.key}:#{obj.id}")
    parts = [link_to("#{l(:label_gk_records_links)}: #{sum[:total]}", href, class: 'gk-records-count', onclick: onclick)]
    sum[:by].each { |key, n| parts << content_tag('span', "#{GkRecords::Targets.thing_label(key)} #{n}", class: 'gk-records-by') }
    marks = sum[:attention].map do |k|
      okey, oid, out = GkRecords::Links.other(k, tdef.key, obj.id)
      kind = GkRecords::Kinds.find(:link, k.kind)
      content_tag('span', safe_join([content_tag('strong', out ? kind.label : (kind.reverse_label || kind.label)), ' ', gk_records_ref_link(okey, oid)]), class: 'gk-records-attention')
    end
    content_tag('p', safe_join(parts + marks, ' '), class: 'gk-records-row')
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

    parts = [content_tag('span', "#{GkRecords::Verification.title}:", class: 'gk-records-count'),
             render(partial: 'gk_records/verification', locals: { obj: obj, back_url: request.fullpath })]
    content_tag('div', safe_join(parts, ' '), class: 'gk-records-row gk-records-verification-row')
  end

  # The row for assessments on a thing: how many and the latest outcome, as the way to the page (or, on an issue,
  # down to the tab). Nothing when there are none.
  def gk_records_assessments_row(obj, href: nil, onclick: nil)
    tdef = GkRecords::Targets.for_object(obj)
    return '' unless tdef

    sum = GkRecords::Assessments.summary(tdef.key, obj.id)
    return '' if sum[:total].zero?

    href ||= gk_records_assessments_page_path(target: "#{tdef.key}:#{obj.id}")
    parts = [link_to("#{l(:label_gk_records_assessments)}: #{sum[:total]}", href, class: 'gk-records-count', onclick: onclick)]
    a = sum[:latest]
    text = [a.outcome.presence, format_date(User.current.time_to_date(a.assessed_at))].compact.join(', ')
    parts << content_tag('span', "#{l(:label_gk_records_latest)}: #{text}", class: 'gk-records-by')
    content_tag('p', safe_join(parts, ' '), class: 'gk-records-row')
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

    content_tag('p', link_to("#{l(:label_gk_records_events)}: #{n}", gk_records_events_path(target: "#{tdef.key}:#{obj.id}"), class: 'gk-records-count'), class: 'gk-records-row')
  end

  # What stands in the column for the state of the thing at the other end: an issue's status, nothing for the rest.
  # A closed status as core's closed badge, so a link to a superseded or outdated source (or any closed issue)
  # shows it at a glance
  def gk_records_other_state(key, id)
    s = GkRecords::Links.state(key, id)
    return '' unless s
    return s[:text] unless s[:closed]

    content_tag('span', s[:text], class: 'badge badge-status-closed gk-records-state-closed')
  end

  # What a thing cites (Links.citations), one line each: the kind, the thing (or the text for one the reader may
  # not see), the place in it, a closed status as a badge and the thing's verification status. '' when it cites
  # nothing. For the owner's page beside its own source text.
  def gk_records_citations(obj)
    links = GkRecords::Links.citations(obj)
    return '' if links.empty?

    gk_records_restricted_assets
    rows = links.map do |k|
      kind = GkRecords::Kinds.find(:link, k.kind)
      parts = [content_tag('span', kind ? kind.label : k.kind, class: 'gk-records-meta'), gk_records_ref_link(k.target_type, k.target_id)]
      shown = GkRecords::Links.thing(k.target_type, k.target_id)
      parts << content_tag('span', k.shown_reason, class: 'gk-records-locator', title: l(:label_gk_records_link_locator)) if shown && k.reason.present?
      s = shown && GkRecords::Links.state(k.target_type, k.target_id)
      parts << content_tag('span', s[:text], class: 'badge badge-status-closed gk-records-state-closed') if s && s[:closed]
      parts << gk_records_verification_badge(shown) if shown
      content_tag('span', safe_join(parts.reject(&:blank?), ' '), class: 'gk-records-citation')
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
    return content_tag('span', l(:text_gk_records_hidden_thing), class: 'gk-records-hidden') unless obj && GkRecords::Targets.visible?(obj)

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
    when :gone then content_tag('span', GkRecords::Ref.gone_thing_text, class: 'gk-records-system')
    else content_tag('span', l(:text_gk_records_hidden_person), class: 'gk-records-hidden')
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
      p ? gk_records_user(p, on: on) : content_tag('span', ref.gone_text, class: 'gk-records-system')
    end
    if ref.one?(v) then one.call(v.values.first)
    elsif ref.many?(v) then safe_join(v.values.first.map { |id| one.call(id) }, ', ')
    elsif ref.thing?(v) then gk_records_thing(ref.at(v, ref::THING), ref.at(v, 'id'), found)
    elsif ref.things?(v) then safe_join(ref.at(v, 'ids').map { |id| gk_records_thing(ref.at(v, ref::THINGS), id, found) }, ', ')
    elsif v.is_a?(Hash) then safe_join(v.map { |k, x| safe_join([k.to_s, ': ', gk_records_value(x, found, on: on)]) }, ', ')
    else safe_join(v.map { |x| gk_records_value(x, found, on: on) }, ', ')
    end
  end

  # A private field the reader may not see (GkRecordsEvent#hidden_fields) is named with the text for a hidden value,
  # never its value.
  # fold: true (the events page, records_1021-SID-26): a row stays short, the first two entries show and the rest fold
  # in a <details> the reader opens with a click; fewer than two when the first ones are long already (300 characters)
  def gk_records_details(event, fold: false)
    d = event.change_details(User.current)
    hidden = event.hidden_fields(User.current)
    return '' if d.blank? && hidden.empty?

    found = GkRecords::Ref.principals(d)
    # the people in the changes are counted for the mark among those who see the event's thing (records_1021-SID-63)
    on = gk_records_event_thing(event)
    rows = d.map do |field, change|
      if change.is_a?(Array) && change.size == 2
        content_tag('li', safe_join([content_tag('strong', field), ': ', content_tag('del', gk_records_value(change[0], found, on: on)), ' ', content_tag('ins', gk_records_value(change[1], found, on: on))]))
      else
        content_tag('li', safe_join([content_tag('strong', field), ': ', gk_records_value(change, found, on: on)]))
      end
    end
    rows += hidden.map { |field| content_tag('li', safe_join([content_tag('strong', field), ': ', content_tag('span', l(:text_gk_records_hidden_value), class: 'gk-records-hidden')])) }
    return safe_join(rows) unless fold

    n = [rows.size, 2].min
    n -= 1 while n > 1 && rows.first(n).sum { |r| strip_tags(r.to_s).length } > 300
    rest = rows.drop(n)
    return safe_join(rows) if rest.empty?

    # one list (records_1021-SID-26, "inte att det liksom blir två listor"): the rest are in the same list, hidden, and
    # "Visa alla (n)" shows them where they stand
    hidden_rows = rest.map { |r| r.to_s.sub(/\A<li/, '<li hidden class="gk-records-more-row"').html_safe }
    show = link_to(l(:text_gk_records_show_all, count: rows.size), '#', class: 'gk-records-show-all',
                   onclick: "var u=this.closest('ul');u.querySelectorAll('li.gk-records-more-row').forEach(function(x){x.hidden=false;});this.parentNode.remove();return false;")
    safe_join(rows.first(n) + hidden_rows + [content_tag('li', show, class: 'gk-records-more-item')])
  end
  # The shared reason field every place draws in place of its own. Nothing when the place is off; required (and a least
  # length) when it is required. The person's latest reason for the place is a greyed suggestion that counts only when
  # chosen (Use the suggestion, or a choice in the list); earlier reasons come as a list on the field, or as buttons under it
  # (chips: true). require: true or false overrides the mode for a fixed place whose owner decides (a rule in
  # workflow_rules). The server decides in any case (GkRecords::Reasons.check).
  # A # in the field opens core's search for issues: text searches, a number shows that issue, a click puts its number
  # in the reason.
  # By the place's mode (no require: given), the field is folded: only the link "Add a reason" (core's add icon) shows,
  # and a click unfolds the field and puts the cursor in it. The link only opens the field; the form's own Save saves.
  # The script moves a folded field after the form's Save: in a table's cell beside it, in a form on its own line under
  # the line with Save and Cancel, never between them. An optional reason stays folded; a required one stands open in a
  # form and folds only in a table's row, except a text area: when the row is sent without it, the script unfolds the
  # field, puts the cursor in it and shows the hint. Without script the field simply shows where it is. A value (a form shown again
  # after a refused save) shows the field unfolded. fold: false never folds; fold: true also folds a field whose
  # require: is given. The server decides as before either way.
  # Open, the field and its buttons stand in one framed group, so the buttons plainly belong to the reason. The buttons
  # are submit buttons so they get core's look and hover; the script keeps them from sending the form.
  # One reason per save: a page with several sections that each had their own Save and reason uses one form around
  # all the sections, calls this helper once for the form's place, beside the one Save at the bottom, and the
  # controller checks that one reason once (GkRecords::Reasons.check) for every change the save makes.
  def gk_records_reason_field(key, name: 'reason', value: nil, id: nil, size: 30, area: false, rows: 2, chips: false, placeholder: nil,
                           require: nil, fold: nil, html: {})
    r = GkRecords::Reasons
    mode = r.mode(key)
    return ''.html_safe if mode == 'off' && require.nil?

    place = r.find(key)
    need = require.nil? ? mode == 'required' : require
    # records_1021-SID-30: no suggestions until a plugin gives a search field of the select2 kind (Reasons.suggest?)
    sug = r.suggest? ? r.suggestions(key) : { latest: nil, list: [] }
    list_id = sug[:list].any? ? "gk-records-rs-#{key.to_s.tr('.', '-')}-#{SecureRandom.hex(3)}" : nil
    ph = sug[:latest] ? l(:text_gk_records_reason_suggest, text: truncate(sug[:latest], length: 60)) : (placeholder || l(:text_gk_records_reason_write))
    opts = { id: id, placeholder: ph, required: need ? true : nil, minlength: (need && place&.min ? place.min : nil), list: list_id,
             autocomplete: 'off', data: { gk_reason: key, gk_reason_suggest: sug[:latest], auto_complete: true } }.merge(html)
    field = area ? text_area_tag(name, value, opts.merge(rows: rows, cols: size)) : text_field_tag(name, value, opts.merge(size: size))
    # the field's buttons: core's submit buttons (core's look and hover), without a name so nothing extra is sent
    btn = ->(text, css, **o) { button_tag(text, { type: 'submit', name: nil, class: css }.merge(o)) }
    parts = [field]
    parts << ' ' << btn.call(l(:button_gk_records_reason_use), 'gk-records-reason-use', title: sug[:latest]) if sug[:latest]
    # Use the reason takes what is written, closes the field and shows the reason as text with Change, for the one who
    # wants to see it so first; the form's Save takes what is written in the same way and sends it (the script; the
    # server decides anyway)
    parts << ' ' << btn.call(l(:button_gk_records_reason_commit), 'gk-records-reason-commit')
    parts << content_tag('span', safe_join([content_tag('span', '', class: 'gk-records-reason-used-text'), ' ',
                                            btn.call(l(:button_gk_records_reason_change), 'gk-records-reason-change')]),
                         class: 'gk-records-reason-used', hidden: true)
    # the hint a required reason gets when the form is sent without it; an optional one never stops the form
    parts << content_tag('span', l(:text_gk_records_reason_commit_required), class: 'gk-records-reason-hint gk-records-meta', hidden: true) if need
    parts << content_tag('datalist', safe_join(sug[:list].map { |t| content_tag('option', '', value: t) }), id: list_id) if list_id
    if chips && sug[:list].any?
      parts << content_tag('span', safe_join(sug[:list].map { |t| btn.call(truncate(t, length: 50), 'gk-records-reason-chip', title: t, data: { reason: t }) }, ' '),
                           class: 'gk-records-reason-chips')
    end
    folded = value.blank? && (fold.nil? ? require.nil? && !(need && area) : fold)
    return content_tag('span', safe_join(parts), class: 'gk-records-reason-wrap gk-records-reason-group') + gk_records_reason_script unless folded

    box_id = "gk-records-rf-#{SecureRandom.hex(4)}"
    # the link is hidden until the script folds the field, so without script only the field shows; it only opens the
    # field, so it says "Add a reason" with core's add icon, as core's own add links
    text = l(:button_gk_records_reason_unfold)
    link = link_to(respond_to?(:sprite_icon) ? sprite_icon('add', text) : text, '#', role: 'button', class: 'icon icon-add gk-records-reason-unfold',
                                                                                     hidden: true, aria: { expanded: 'false', controls: box_id })
    # an unfolded reason folds back (the field emptied); an optional one then goes without a reason, a required one is
    # asked for again when the form is sent
    parts << ' ' << btn.call('×', 'gk-records-reason-close', title: l(:button_gk_records_reason_close),
                                                            aria: { label: l(:button_gk_records_reason_close) })
    content_tag('span', safe_join([link, content_tag('span', safe_join(parts), id: box_id, class: 'gk-records-reason-box gk-records-reason-group')]),
                class: 'gk-records-reason-wrap gk-records-reason-fold') + gk_records_reason_script
  end

  # once per page: the suggestion and a chip put the reason in the field beside them; a folded field is hidden behind
  # its link "Add a reason", which unfolds it and puts the cursor in it, and stands after the button that saves its
  # form. The form's Save takes the reason that is written, as Use the reason does, and sends it; an empty optional
  # reason never stops it. A required reason left empty stops the form (the browser's own check, or the field's hint;
  # a folded one is unfolded with the cursor in it). Fields added later (a form fetched into a popup) are folded when
  # they appear. The field's buttons are submit buttons for core's look; a click on one never sends the form.
  def gk_records_reason_script
    return ''.html_safe if @gk_records_reason_script

    @gk_records_reason_script = true
    # the field's own rules (the frame, the folding) on a page of another plugin too; once, as the restricted mark does
    gk_records_restricted_assets
    javascript_tag(<<~JS)
      (function () {
        if (window.gkRecordsReasonBound) return;
        window.gkRecordsReasonBound = true;
        // the browser's own "Please fill in this field" is in the browser's language; the reason field says it in the
        // page's (records' texts), and is plain again once something is written
        var MISSING = #{l(:error_gk_records_reason_required).to_json}, SHORT = #{l(:error_gk_records_reason_short).to_json};
        document.addEventListener('invalid', function (e) {
          var f = e.target;
          if (!f.matches || !f.matches('[data-gk-reason]')) return;
          if (f.validity.valueMissing) f.setCustomValidity(MISSING);
          else if (f.validity.tooShort) f.setCustomValidity(SHORT.replace('%{count}', String(f.minLength)));
        }, true);
        document.addEventListener('input', function (e) {
          var f = e.target;
          if (f.matches && f.matches('[data-gk-reason]')) f.setCustomValidity('');
        }, true);
        var SUBMIT = 'input[type=submit], button[type=submit], button:not([type])';
        var after = function (w, b) { return !!(w.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING); };
        // the button that saves the field's form in the same row: the last one after the field in its own element, or
        // else the button (or the paragraph of buttons) that comes right after the field's element, up to the form
        var saveButton = function (w, f) {
          var form = f && f.form; if (!form) return null;
          var mine = function (b) { return b.form === form && !w.contains(b); };
          var row = w.parentElement;
          var own = row ? Array.prototype.filter.call(row.querySelectorAll(SUBMIT), function (b) { return mine(b) && after(w, b); }) : [];
          if (own.length) return own[own.length - 1];
          for (var el = row; el && el !== form && form.contains(el); el = el.parentElement) {
            var next = el.nextElementSibling;
            if (!next) continue;
            if (next.matches(SUBMIT)) return mine(next) ? next : null;
            if (next.tagName !== 'P') return null;
            var bs = Array.prototype.filter.call(next.querySelectorAll(SUBMIT), mine);
            return bs.length ? bs[bs.length - 1] : null;
          }
          return null;
        };
        // a folded field stands after the button that saves, so the button comes first: in a table's cell beside the
        // button, as before; in a form on its own line under the button's line, so that Save and Cancel stay side by
        // side and the reason is never between them
        var place = function (w, f) {
          var b = saveButton(w, f);
          if (!b || !after(w, b)) return;
          if (b.closest('td')) {
            b.parentNode.insertBefore(w, b.nextSibling);
            b.parentNode.insertBefore(document.createTextNode(' '), w);
            return;
          }
          var line = b.parentNode, form = b.form;
          while (line && line !== form && line.parentNode !== form && getComputedStyle(line).display.indexOf('inline') === 0) line = line.parentNode;
          if (!line || line === form) line = b;
          var under = document.createElement('p'); under.className = 'gk-records-reason-under';
          under.appendChild(w);
          line.parentNode.insertBefore(under, line.nextSibling);
        };
        // a required field that is folded is not required to the browser (a hidden required field would stop the form
        // without a word); the script asks for it when the form is sent, and the browser again once it is unfolded
        var needs = function (f) { return !!f && (f.required || f.hasAttribute('data-gk-reason-required')); };
        var hide = function (box, f, on) {
          box.hidden = on;
          if (!f || !needs(f)) return;
          f.required = !on;
          if (on) f.setAttribute('data-gk-reason-required', '1'); else f.removeAttribute('data-gk-reason-required');
        };
        var fold = function (root) {
          if (!root || !root.querySelectorAll) return;
          var list = Array.prototype.slice.call(root.querySelectorAll('.gk-records-reason-fold:not([data-gk-folded])'));
          if (root.matches && root.matches('.gk-records-reason-fold:not([data-gk-folded])')) list.push(root);
          list.forEach(function (w) {
            var a = w.querySelector('.gk-records-reason-unfold'); var box = w.querySelector('.gk-records-reason-box');
            if (!a || !box) return;
            w.setAttribute('data-gk-folded', '1');
            var f = box.querySelector('[data-gk-reason]');
            place(w, f);
            if (f && f.value) return;
            // a required reason in a form stands open, so that it is seen to be required; folded only in a table's
            // row (the row stays short) and when optional, behind "Add a reason"
            if (needs(f) && !w.closest('td')) return;
            hide(box, f, true);
            a.hidden = false;
          });
        };
        var unfold = function (a, quiet) {
          var w = a.closest('.gk-records-reason-fold'); var box = w && w.querySelector('.gk-records-reason-box');
          if (!box) return;
          var f = box.querySelector('[data-gk-reason]');
          hide(box, f, false);
          a.setAttribute('aria-expanded', 'true');
          a.hidden = true;
          size(f && f.form);
          if (f && !quiet) f.focus();
        };
        // Use the reason shows what was written as text (the field kept, hidden, so it is sent); Change opens the
        // field again
        // no wrap (the settings pages' field, which has its own script): nothing here
        var parts = function (w) {
          if (!w) return {};
          return { f: w.querySelector('[data-gk-reason]'), commit: w.querySelector('.gk-records-reason-commit'), used: w.querySelector('.gk-records-reason-used'),
                   hint: w.querySelector('.gk-records-reason-hint') };
        };
        // a field that stands open with a reason not used: an unfolded one (also empty), else a required one or one
        // with text; used or folded, it is not open
        var isOpen = function (w) {
          var p = parts(w);
          if (!p.f || w.getAttribute('data-gk-reason-state') === 'used') return false;
          var box = w.querySelector('.gk-records-reason-box');
          if (box && box.hidden) return false;
          return !!box || p.f.required || p.f.value.trim() !== '';
        };
        // the field's buttons as high as the form's Save, whatever the theme makes it (records_1021-SID-59, 65); a Save
        // not shown yet (Ändra status closed) has no height, and is measured again when the field opens. Save itself
        // is never turned off for the reason: it takes what is written (stop)
        var size = function (form) {
          if (!form) return;
          var wraps = form.querySelectorAll('.gk-records-reason-wrap');
          var saveH = 0;
          Array.prototype.some.call(form.querySelectorAll(SUBMIT), function (b) {
            if (b.closest('.gk-records-reason-wrap') || b.form !== form || !b.offsetHeight) return false;
            saveH = b.offsetHeight; return true;
          });
          if (saveH) Array.prototype.forEach.call(wraps, function (w) { w.style.setProperty('--gk-reason-btn', saveH + 'px'); });
        };
        var formOf = function (w) { var p = parts(w); return p.f && p.f.form; };
        // quiet: Save took the reason as the form goes, so the cursor stays where it is
        var use = function (w, quiet) {
          var p = parts(w); if (!p.f) return;
          if (!p.f.value.trim()) { if (!quiet) p.f.focus(); return; }
          p.used.querySelector('.gk-records-reason-used-text').textContent = p.f.value.trim();
          p.f.hidden = true; p.commit.hidden = true; p.used.hidden = false; if (p.hint) p.hint.hidden = true;
          w.setAttribute('data-gk-reason-state', 'used');
          size(formOf(w));
          if (!quiet) p.used.querySelector('.gk-records-reason-change').focus();
        };
        // Change: the field again with the text that was used, Use the reason beside it and Change hidden
        var change = function (w) {
          var p = parts(w); if (!p.f) return;
          p.f.hidden = false; p.commit.hidden = false; p.used.hidden = true;
          w.removeAttribute('data-gk-reason-state');
          size(formOf(w));
          p.f.focus();
        };
        // folds an unfolded field back: emptied and hidden behind its link again
        var close = function (c) {
          var w = c.closest('.gk-records-reason-fold'); var box = w && w.querySelector('.gk-records-reason-box');
          var a = w && w.querySelector('.gk-records-reason-unfold');
          if (!box || !a) return;
          var f = box.querySelector('[data-gk-reason]');
          if (f) { f.value = ''; f.dispatchEvent(new Event('input', { bubbles: true })); }
          change(w);
          hide(box, f, true);
          var hint = parts(w).hint; if (hint) hint.hidden = true;
          a.hidden = false;
          a.setAttribute('aria-expanded', 'false');
          size(f && f.form);
          a.focus();
        };
        // a folded required field with no reason used: the form is sent without the reason it needs
        var missing = function (w) {
          var box = w.querySelector('.gk-records-reason-box'); var p = parts(w);
          return !!box && box.hidden && needs(p.f) && w.getAttribute('data-gk-reason-state') !== 'used' && !p.f.value.trim();
        };
        // When the form is sent (its Save, or Enter in another field): a reason written and not used yet is taken as
        // Use the reason takes it, and the form goes with it; an empty optional reason goes without one. A required
        // reason that is empty stops the form: a folded one is unfolded, and the hint shows with the cursor in the
        // field (an open one is usually stopped first by the browser's own check, since it is required there). A
        // field that is not shown (its part of the form hidden) is left to the form and the server.
        var stop = function (form) {
          var lacking = [];
          Array.prototype.forEach.call(form.querySelectorAll('.gk-records-reason-wrap'), function (w) {
            var p = parts(w);
            if (!p.f || !w.getClientRects().length) return;
            if (missing(w)) { unfold(w.querySelector('.gk-records-reason-unfold'), true); lacking.push(w); return; }
            if (!isOpen(w)) return;
            if (p.f.value.trim()) { use(w, true); return; }
            if (needs(p.f)) lacking.push(w);
          });
          if (!lacking.length) return false;
          lacking.forEach(function (w) { var p = parts(w); if (p.hint) p.hint.hidden = false; });
          parts(lacking[0]).f.focus();
          return true;
        };
        document.addEventListener('submit', function (e) {
          if (stop(e.target)) e.preventDefault();
        }, true);
        // Enter in another field of the form clicks the form's first submit button, which may be one of the field's
        // (a field that stands before Save): the form is sent as by its own Save instead
        var implicit = function (b) {
          var form = b.form; if (!form) return;
          var save = Array.prototype.filter.call(form.querySelectorAll(SUBMIT), function (x) { return x.form === form && !x.closest('.gk-records-reason-wrap'); })[0];
          if (stop(form) || !save || save.disabled) return;
          if (form.requestSubmit) form.requestSubmit(save); else save.click();
        };
        window.gkRecordsReasonFold = fold;
        fold(document);
        // the script runs right after the first field, before the button that saves exists: every folded field is
        // placed again when the page is read (Save first, then "Add a reason")
        var sizeAll = function (root) {
          if (!root || !root.querySelectorAll) return;
          var forms = [];
          root.querySelectorAll('.gk-records-reason-wrap').forEach(function (w) { var form = formOf(w); if (form && forms.indexOf(form) < 0) forms.push(form); });
          forms.forEach(size);
        };
        document.addEventListener('DOMContentLoaded', function () {
          fold(document);
          document.querySelectorAll('.gk-records-reason-fold').forEach(function (w) { place(w, w.querySelector('[data-gk-reason]')); });
          sizeAll(document);
        });
        // a reason written after the hint showed: the hint goes
        document.addEventListener('input', function (e) {
          var w = e.target.closest ? e.target.closest('.gk-records-reason-wrap') : null;
          if (!w || !e.target.matches('[data-gk-reason]') || !e.target.value.trim()) return;
          var hint = parts(w).hint; if (hint) hint.hidden = true;
        });
        // Enter in a reason's line uses it, as Use the reason does, instead of sending the form
        document.addEventListener('keydown', function (e) {
          if (e.key !== 'Enter' || !e.target.matches || !e.target.matches('input[data-gk-reason]')) return;
          var w = e.target.closest('.gk-records-reason-wrap');
          if (!w || !w.querySelector('.gk-records-reason-commit')) return;
          e.preventDefault();
          use(w);
        });
        if (window.MutationObserver) {
          new MutationObserver(function (ms) {
            ms.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1) { fold(n); sizeAll(n); } }); });
          }).observe(document.documentElement, { childList: true, subtree: true });
        }
        document.addEventListener('keydown', function (e) {
          if (e.key !== ' ' && e.key !== 'Spacebar') return;
          var a = e.target.closest ? e.target.closest('.gk-records-reason-unfold') : null;
          if (!a) return;
          e.preventDefault();
          unfold(a);
        });
        document.addEventListener('click', function (e) {
          // a click on one of the field's buttons never sends the form; a click no pointer or key on the button made
          // (detail 0, the focus elsewhere) is Enter in another field, and the form goes as by its Save
          var own = e.target.closest ? e.target.closest('.gk-records-reason-wrap button') : null;
          if (own) {
            e.preventDefault();
            if (e.detail === 0 && document.activeElement !== own) { implicit(own); return; }
          }
          var u = e.target.closest ? e.target.closest('.gk-records-reason-unfold') : null;
          if (u) { e.preventDefault(); unfold(u); return; }
          var c = e.target.closest ? e.target.closest('.gk-records-reason-close') : null;
          if (c) { e.preventDefault(); close(c); return; }
          var cm = e.target.closest ? e.target.closest('.gk-records-reason-commit') : null;
          if (cm) { e.preventDefault(); use(cm.closest('.gk-records-reason-wrap')); return; }
          var ch = e.target.closest ? e.target.closest('.gk-records-reason-change') : null;
          if (ch) { e.preventDefault(); change(ch.closest('.gk-records-reason-wrap')); return; }
          var b = e.target.closest ? e.target.closest('.gk-records-reason-use, .gk-records-reason-chip') : null;
          if (!b) return;
          var w = b.closest('.gk-records-reason-wrap'); var f = w && w.querySelector('[data-gk-reason]');
          if (!f) return;
          e.preventDefault();
          f.value = b.classList.contains('gk-records-reason-chip') ? b.getAttribute('data-reason') : (f.getAttribute('data-gk-reason-suggest') || '');
          f.dispatchEvent(new Event('input', { bubbles: true }));
          f.focus();
        });
      })();
    JS
  end
end
