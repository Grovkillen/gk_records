# frozen_string_literal: true

module GkRecords
  # Who may be named to whom: records never shows the name of a person the reader may not see by core's own rule
  # (User.visible for people, Principal.visible for groups). That holds for everything records shows: who did an
  # event and for whom, who wrote, corrected or voided a note, who made a link, who assessed, the settings' history,
  # the query Händelser (columns, grouping, sorting and the filter on user), CSV, REST and the view helpers other
  # plugins use. A person the reader may not see is "en person du inte får se"; REST gives null for the id and a
  # mark that a person is hidden. Administrators see all, as in core.
  # One place for the test: views, helpers, the query and the JSON all ask here.
  module Visibility
    module_function

    def reader(user = nil) = user || ::User.current

    def hidden_text = ::I18n.t(:text_gk_records_hidden_person)

    # Core's built-in principals (Anonymous, the deleted user, the built-in groups) are no person and stay as core
    # shows them
    def builtin?(user)
      user.is_a?(::AnonymousUser) || (defined?(::DeletedUser) && user.is_a?(::DeletedUser)) ||
        (defined?(::GroupBuiltin) && user.is_a?(::GroupBuiltin))
    end

    # May the viewer see this person (or group)? No person (the system) hides nothing. The answer is kept on the
    # viewer object, which core makes new for every request, so a list asks the database once per person.
    def visible_user?(user, viewer = nil)
      return true if user.nil?

      v = reader(viewer)
      return true if v.admin? || user.id == v.id || builtin?(user)

      cache = v.instance_variable_get(:@gk_records_visible_users) || v.instance_variable_set(:@gk_records_visible_users, {})
      return cache[user.id] if cache.key?(user.id)

      scope = user.is_a?(::Group) ? ::Principal.visible(v) : ::User.visible(v)
      cache[user.id] = scope.where(id: user.id).exists?
    end

    # The name, or the neutral text; no person gives system (the text for "systemet", or what the caller asks for)
    def name_for(user, viewer = nil, system: ::I18n.t(:label_gk_records_by_system))
      return system if user.nil?

      visible_user?(user, viewer) ? user.name : hidden_text
    end

    # What a query column shows for a person: the user (core formats it as a link) or the neutral text
    def shown(user, viewer = nil)
      user.nil? || visible_user?(user, viewer) ? user : hidden_text
    end

    # Of the given user ids (strings, as a filter holds them), those the viewer may see (herself and core's
    # Anonymous always)
    def visible_user_ids(ids, viewer = nil)
      v = reader(viewer)
      ids = Array(ids).map(&:to_s).reject(&:blank?)
      return ids if v.admin? || ids.empty?

      shown = ::User.visible(v).where(id: ids.map(&:to_i)).pluck(:id).map(&:to_s) | [v.id.to_s, ::User.anonymous.id.to_s]
      ids.select { |i| shown.include?(i) }
    end

    # A user id column as SQL for grouping and sorting: a person the viewer may not see becomes 0, so all hidden
    # people fall in one group and their order says nothing about who they are
    def user_id_sql(column, viewer = nil)
      v = reader(viewer)
      return column if v.admin?

      "(CASE WHEN #{column} IS NULL THEN NULL WHEN #{column} = #{v.id.to_i} OR #{column} IN (#{::User.visible(v).select(:id).to_sql}) " \
        "THEN #{column} ELSE 0 END)"
    end

    # For REST: { "user_id" => id } or { "user_id" => nil, "user_hidden" => true } when the person is hidden; a person
    # shown whom some other user may not see also carries user_restricted and user_hidden_from (api_restricted)
    def api_user(key, id, user, viewer = nil)
      return { key => id } if id.nil? || user.nil?
      return { key => id }.merge(api_restricted(key, user, viewer)) if visible_user?(user, viewer)

      { key => nil, key.to_s.sub(/_id\z/, '_hidden').to_sym => true }
    end

    # People not everyone may see: a person (or group) the viewer may see but some other active user may not, by
    # core's own rule (Principal.visible for each of them), is marked where records shows the name. Only how many
    # may not see her is told, never who.
    # Counted over the active users that are no administrator (administrators see all) and not Anonymous. A user
    # sees all active people unless every role she has (or, without memberships, the non member role) has
    # users_visibility "members_of_visible_projects"; then she sees herself and the members of the projects she may
    # see. A person who is not active (locked) is seen by administrators only, so every other active user counts.
    RESTRICTING = 'members_of_visible_projects'
    CACHE_TTL = 600 # seconds

    # Is the mark on? It holds for every plugin using the helpers.
    def mark?
      ::Setting.plugin_gk_records['mark_restricted_people'].to_s != '0'
    rescue StandardError
      true
    end

    # Does any role restrict who its members see? Anonymous never counts (no person is shown to the mark).
    def any_restricting_role?
      ::Role.givable.where(users_visibility: RESTRICTING).exists? || ::Role.non_member.users_visibility == RESTRICTING
    end

    # The active users the mark counts: no administrator, no Anonymous, no built-in
    def counted_users = ::User.where(type: 'User', status: ::Principal::STATUS_ACTIVE, admin: false)

    # Principals that are not active: seen by administrators only
    def inactive_ids = ::Principal.where(type: %w[User Group]).where.not(status: ::Principal::STATUS_ACTIVE).pluck(:id)

    # Does this user see only some people? Core's own test in Principal.visible (view_all_active false).
    def restricted_viewer?(user)
      ms = user.memberships.to_a
      ms.any? ? ms.none? { |m| m.roles.any? { |r| r.users_visibility == 'all' } } : ::Role.non_member.users_visibility != 'all'
    end

    # What the map depends on, cheap to ask: people, memberships and their roles, roles, projects and their modules,
    # group members. member_roles, roles and groups_users carry no time stamps in core, so their counts, highest ids
    # and the roles' own columns stand in; the time limit (CACHE_TTL) catches what may still slip by (a column
    # changed without a time stamp).
    def map_key
      conn = ::Principal.connection
      parts = [
        ::Principal.maximum(:updated_on).to_i, ::Principal.count,
        ::Member.count, ::Member.maximum(:id).to_i, ::MemberRole.count, ::MemberRole.maximum(:id).to_i,
        ::Role.order(:id).pluck(:id, :users_visibility, :permissions).to_s,
        ::Project.maximum(:updated_on).to_i, ::Project.count, ::EnabledModule.count, ::EnabledModule.maximum(:id).to_i,
        conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name('groups_users')}").to_i
      ]
      "gk_records/restricted/#{::Digest::SHA256.hexdigest(parts.join('/'))}"
    end

    # { principal id => the ids of the counted users who may not see her }; only people some user may not see are in
    # it. Who they are stays here: it is counted against those who see a thing (hidden_from_count on:), never shown.
    def build_map
      out = Hash.new { |h, k| h[k] = [] }
      restricted, open = counted_users.preload(memberships: :roles).to_a.partition { |v| restricted_viewer?(v) }
      open_ids = open.map(&:id)
      inactive_ids.each { |id| out[id].concat(open_ids) } unless open_ids.empty?
      unless restricted.empty?
        everyone = ::Principal.where(type: %w[User Group]).pluck(:id)
        restricted.each do |v|
          seen = ::Principal.visible(v).pluck(:id) << v.id
          (everyone - seen).each { |id| out[id] << v.id }
        end
      end
      out.reject { |_id, ids| ids.empty? }.to_h
    end

    # The map for this request: kept on the reader (new for every request) and across requests in Rails.cache under
    # a key that changes when people, memberships, roles or projects change (and at the latest after CACHE_TTL).
    # No restricting role: only the people who are not active are in it, counted without asking user by user.
    def restricted_map(viewer = nil)
      v = reader(viewer)
      memo = v.instance_variable_get(:@gk_records_restricted_map)
      return memo if memo

      map = if any_restricting_role?
              # the cached form before rc15 held a count per person; a map of counts is built again
              m = ::Rails.cache.fetch("#{map_key}/ids", expires_in: CACHE_TTL) { build_map }
              m.is_a?(Hash) && m.values.all?(Array) ? m : build_map
            else
              ids = inactive_ids
              all = ids.empty? ? [] : counted_users.pluck(:id)
              all.empty? ? {} : ids.to_h { |id| [id, all] }
            end
      v.instance_variable_set(:@gk_records_restricted_map, map)
    end

    # The counted users who may see the thing (Targets.visible?), kept on the reader for the request; nil for no thing
    # or one records does not know (then the whole installation counts)
    def seers_of(thing, viewer = nil)
      return nil unless thing && Targets.for_object(thing) && thing.respond_to?(:id) && thing.id

      v = reader(viewer)
      memo = v.instance_variable_get(:@gk_records_seers) || v.instance_variable_set(:@gk_records_seers, {})
      memo[[thing.class.name, thing.id]] ||= counted_users.to_a.select { |u| Targets.visible?(thing, u) }.map(&:id)
    rescue StandardError => e
      Rails.logger.warn("[gk_records] who sees #{thing.class.name} #{thing&.id} not asked: #{e.class} #{e.message}") if defined?(Rails)
      nil
    end

    # How many counted users may not see the person (0 for none, for nobody and for core's built-in principals).
    # on: the thing the name stands on (an issue, a link's thing, an event's target): only those who may see that thing
    # count, so the mark says that others reading this see "en person" where the reader sees a name (records_1021-SID-63,
    # the owner's choice "De som ser saken"). Without a thing, every counted user in the installation.
    def hidden_from_count(principal, viewer = nil, on: nil)
      return 0 if principal.nil? || builtin?(principal)

      hiders = restricted_map(viewer)[principal.id]
      return 0 if hiders.blank?

      seers = seers_of(on, viewer)
      seers ? (hiders & seers).size : hiders.size
    end

    def restricted?(principal, viewer = nil, on: nil) = hidden_from_count(principal, viewer, on: on).positive?

    # What a page built in JavaScript puts in its JSON: { restricted: true, hidden_from: N, on: true|false } when the
    # viewer may see the person, the mark is on and some user may not; otherwise { restricted: false }. on says whether
    # it was counted among those who see a thing (the text differs).
    def restricted_info(principal, viewer = nil, on: nil)
      return { restricted: false } unless principal && mark? && visible_user?(principal, viewer)

      n = hidden_from_count(principal, viewer, on: on)
      n.positive? ? { restricted: true, hidden_from: n, on: !seers_of(on, viewer).nil? } : { restricted: false }
    end

    # The text for the hover and for screen readers: among those who see the thing, or in the whole installation
    def restricted_title(count, on: false)
      ::I18n.t(on ? :text_gk_records_restricted_on : :text_gk_records_restricted, count: count.to_i)
    end

    # The short text after a name in text output (CSV, plain text): "" when there is no mark
    def restricted_suffix(count) = count.to_i.positive? && mark? ? " (#{::I18n.t(:label_gk_records_restricted_short)})" : ''

    # The name as text output gives it: name_for, with the short text when the viewer sees the person and the mark holds
    def marked_name(user, viewer = nil, system: ::I18n.t(:label_gk_records_by_system), on: nil)
      info = restricted_info(user, viewer, on: on)
      name_for(user, viewer, system: system) + (info[:restricted] ? restricted_suffix(info[:hidden_from]) : '')
    end

    # For REST, beside a person shown: { user_restricted: true, user_hidden_from: N } (the prefix from the key; nil
    # gives restricted and hidden_from), nothing when the mark does not hold
    def api_restricted(key, user, viewer = nil, on: nil)
      info = restricted_info(user, viewer, on: on)
      return {} unless info[:restricted]

      pre = key ? "#{key.to_s.sub(/_id\z/, '')}_" : ''
      { :"#{pre}restricted" => true, :"#{pre}hidden_from" => info[:hidden_from] }
    end
  end

  # People in an event's details: the details never carry a person's name in plain text. A writer gives the person as a
  # reference and records makes it a name when it is shown, by GkRecords::Visibility, so a person the reader may not see
  # is "en person du inte får se" and a renamed person is shown by her name of today.
  # The stored form: one person (user or group, any Principal) is { "principal" => id }; a list of people is
  # { "principals" => [id, ...] } (so a list of two is never read as a change [before, after]). Both may stand
  # alone, inside a list, inside a hash or as either side of a change. A writer never builds them by hand:
  #   details: { "assigned_to" => GkRecords::Ref.change(old_user, new_user),
  #              "member" => GkRecords::Ref.person(user), "readers" => GkRecords::Ref.people(users) }
  # A Principal object put in the details as it is becomes a reference when the event is written (Events.write).
  # Shown: the name, "en person du inte får se", or core's name for a principal that no longer exists. REST: a
  # person shown is { "principal" => id, "name" => name }, a hidden one { "principal" => nil, "hidden" => true }.
  # Older details written with names in plain text are shown as they were written.
  #
  # People who are no Principal: people's register people and person groups, and later ones like them, are a reference
  # of a kind another plugin registers, so records never needs to know them. The stored form is { "ref" => kind, "id" =>
  # id } for one and { "refs" => kind, "ids" => [id,...] } for a list; both stand wherever a principal reference may.
  # The owner registers how to name one for a viewer and where it lives: GkRecords::Ref.register_kind(:person,
  # plugin::gk_people, label: ->(id, viewer) { name, nil when the viewer may not see it,:gone when there is none }, url:
  # ->(id, viewer) { the address or nil }) and writes it with GkRecords::Ref.thing(:person, id),.things(:person, ids)
  # or.thing_change(:person, before, after).
  # Shown: the name (a link when url gives one), "en person du inte får se" when label gives nil, when the kind is not
  # registered (its plugin is not there) or when the lookup fails, and "en borttagen person" when label gives :gone.
  # REST: one shown is { "ref" => kind, "id" => id, "name" => name }, a hidden one { "ref" => kind, "hidden" => true }
  # without the id, a gone one { "ref" => kind, "id" => id, "name" => text, "deleted" => true }; a list is
  # { "refs" => kind, "items" => [...] } with the same form for each.
  module Ref
    ONE = 'principal'
    MANY = 'principals'
    THING = 'ref'
    THINGS = 'refs'
    KIND_NAME = /\A[a-z][a-z0-9_]*\z/

    # A registered kind of reference: label (id, viewer) gives the name, nil for hidden or :gone; url (id, viewer)
    # the address or nil; restricted (id) how many active users may not see it, nil or 0 for none (the mark, as
    # Visibility.hidden_from_count for people); list (viewer, query) the ones the viewer may see as [[id, name], ...]
    ThingKind = Struct.new(:key, :plugin, :label, :url, :restricted, :list, keyword_init: true)

    module_function

    def kinds = (@kinds ||= {})

    # Another plugin registers a kind of reference (again after a reload replaces it). principal is core's own and
    # is refused, so is a name that is not a plain key. restricted: and list: are optional; without restricted the
    # kind is never marked, without list Ref.list_kind gives [].
    def register_kind(kind, label:, plugin:, url: nil, restricted: nil, list: nil)
      key = kind.to_s
      raise ArgumentError, "reference kind #{key.inspect}: a plain key such as person" unless key.match?(KIND_NAME)
      raise ArgumentError, "reference kind #{key}: principal is records' own form (Ref.person)" if [ONE, MANY].include?(key)
      raise ArgumentError, "reference kind #{key}: label must answer call(id, viewer)" unless label.respond_to?(:call)
      raise ArgumentError, "reference kind #{key}: restricted must answer call(id)" unless restricted.nil? || restricted.respond_to?(:call)
      raise ArgumentError, "reference kind #{key}: list must answer call(viewer, query)" unless list.nil? || list.respond_to?(:call)

      kinds[key] = ThingKind.new(key: key, plugin: plugin.to_s, label: label, url: url, restricted: restricted, list: list)
    end

    # The things of a kind the viewer may see, for a form in another plugin (triggers): [[id, name], ...] as the
    # owner's list gives them, narrowed by query when the owner reads it; [] when the kind has no list, is not
    # registered or the lookup fails
    def list_kind(kind, viewer = nil, query = nil)
      k = kinds[kind.to_s]
      return [] unless k&.list

      Array(k.list.call(Visibility.reader(viewer), query)).filter_map do |pair|
        id, name = Array(pair)
        id = thing_id_of(id) rescue nil
        id && name.is_a?(String) && !name.strip.empty? ? [id, name] : nil
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_records] reference kind #{kind} list failed: #{e.class} #{e.message}") if defined?(Rails)
      []
    end

    # How many active users may not see a thing of a kind, by the owner's restricted; 0 when it has none or fails
    def thing_hidden_from(kind, id)
      k = kinds[kind.to_s]
      return 0 unless k&.restricted

      n = k.restricted.call(id)
      n.is_a?(Integer) && n.positive? ? n : 0
    rescue StandardError => e
      Rails.logger.warn("[gk_records] reference kind #{kind} restricted failed on #{id}: #{e.class} #{e.message}") if defined?(Rails)
      0
    end

    # As Visibility.restricted_info, for a thing the viewer may see: { restricted: true, hidden_from: N } or
    # { restricted: false }
    def thing_restricted_info(kind, id, viewer = nil, found = nil)
      r = resolve_thing(kind, id, viewer, found)
      r.first == :shown && r[3].to_i.positive? ? { restricted: true, hidden_from: r[3] } : { restricted: false }
    end

    def kind(kind) = kinds[kind.to_s]

    # The id of a Principal, an id, or a string of digits; nil for nothing
    def id_of(user_or_id)
      case user_or_id
      when nil then nil
      when ::Principal then user_or_id.id
      when Integer then user_or_id
      when /\A\d+\z/ then user_or_id.to_i
      when String then user_or_id.strip.empty? ? nil : raise(ArgumentError, "not a person: #{user_or_id.inspect}")
      else raise ArgumentError, "not a person: #{user_or_id.class.name}"
      end
    end

    # One person (or group): { "principal" => id }, nil for nothing
    def person(user_or_id)
      id = id_of(user_or_id)
      id ? { ONE => id } : nil
    end

    # A list of people: { "principals" => [id, ...] }, in the order given
    def people(list) = { MANY => Array(list).filter_map { |u| id_of(u) } }

    # A change of person: [before, after], either side nil for nobody
    def change(before, after) = [person(before), person(after)]

    # The id of a thing that is no Principal: an id, a string of digits or an object with an id; nil for nothing
    def thing_id_of(obj_or_id)
      case obj_or_id
      when nil then nil
      when Integer then obj_or_id
      when /\A\d+\z/ then obj_or_id.to_i
      when String then obj_or_id.strip.empty? ? nil : raise(ArgumentError, "not an id: #{obj_or_id.inspect}")
      else obj_or_id.respond_to?(:id) && obj_or_id.id.is_a?(Integer) ? obj_or_id.id : raise(ArgumentError, "not an id: #{obj_or_id.class.name}")
      end
    end

    def kind_key(kind)
      key = kind.to_s
      raise ArgumentError, "reference kind #{key.inspect}: a plain key such as person" unless key.match?(KIND_NAME) && ![ONE, MANY].include?(key)

      key
    end

    # One thing of a registered kind (a register person): { "ref" => "person", "id" => id }, nil for nothing. The
    # kind need not be registered when it is written; it is looked up when it is shown.
    def thing(kind, obj_or_id)
      id = thing_id_of(obj_or_id)
      id ? { THING => kind_key(kind), 'id' => id } : nil
    end

    # A list of things of one kind: { "refs" => "person", "ids" => [id, ...] }, in the order given
    def things(kind, list) = { THINGS => kind_key(kind), 'ids' => Array(list).filter_map { |x| thing_id_of(x) } }

    # A change of thing: [before, after], either side nil for nothing
    def thing_change(kind, before, after) = [thing(kind, before), thing(kind, after)]

    # The value of a key given as a string or a symbol
    def at(v, key) = v.key?(key) ? v[key] : v[key.to_sym]

    def keys_are?(v, *keys) = v.is_a?(Hash) && v.size == keys.size && v.keys.map(&:to_s).sort == keys.sort

    def thing?(v)
      keys_are?(v, THING, 'id') && at(v, THING).is_a?(String) && at(v, THING).match?(KIND_NAME) && at(v, 'id').is_a?(Integer)
    end

    def things?(v)
      keys_are?(v, THINGS, 'ids') && at(v, THINGS).is_a?(String) && at(v, THINGS).match?(KIND_NAME) &&
        at(v, 'ids').is_a?(Array) && at(v, 'ids').all?(Integer)
    end

    def one?(v) = v.is_a?(Hash) && v.size == 1 && v.keys.first.to_s == ONE && v.values.first.is_a?(Integer)

    def many?(v)
      v.is_a?(Hash) && v.size == 1 && v.keys.first.to_s == MANY && v.values.first.is_a?(Array) && v.values.first.all?(Integer)
    end

    # Any reference: a principal or principals, or a thing or things of a registered kind
    def ref?(v) = one?(v) || many?(v) || thing?(v) || things?(v)

    # Does the value hold a reference anywhere?
    def any?(v)
      return true if ref?(v)

      case v
      when Hash then v.values.any? { |x| any?(x) }
      when Array then v.any? { |x| any?(x) }
      else false
      end
    end

    # Every principal id referred to in the value (things of other kinds are not principals and are left out)
    def ids(v, out = [])
      if one?(v) then out << v.values.first
      elsif many?(v) then out.concat(v.values.first)
      elsif thing?(v) || things?(v) then out
      elsif v.is_a?(Hash) then v.each_value { |x| ids(x, out) }
      elsif v.is_a?(Array) then v.each { |x| ids(x, out) }
      end
      out
    end

    # The principals of a value, loaded at once: { id => principal }
    def principals(v)
      found = ids(v).uniq
      found.empty? ? {} : ::Principal.where(id: found).index_by(&:id)
    end

    # Before writing: a Principal object anywhere in the details becomes a reference (never the whole object, which
    # would carry its login and more)
    def normalize(v)
      case v
      when ::Principal then person(v)
      when Hash then ref?(v) ? v : v.to_h { |k, x| [k, normalize(x)] }
      when Array then v.map { |x| normalize(x) }
      else v
      end
    end

    # What core calls a principal that is gone (Anonym, or the deleted user where core has one)
    def gone_text
      deleted = defined?(::DeletedUser) && ::DeletedUser.respond_to?(:first) ? (::DeletedUser.first rescue nil) : nil
      (deleted || ::User.anonymous).name
    end

    # The name of one id for the viewer, with the short text of the mark when it holds (mark: false leaves it out)
    def name_of(id, found, viewer = nil, mark: true)
      p = found[id]
      return gone_text unless p

      mark ? Visibility.marked_name(p, viewer) : Visibility.name_for(p, viewer)
    end

    # One thing for the viewer, asked of its registered kind once per value shown (kept in found under [kind, id]):
    # [:shown, name, url, hidden_from], [:hidden] or [:gone]; hidden_from (0 when none) is asked of the kind's
    # restricted only while the mark is on. A kind nobody registered, a label that is not a text and a lookup
    # that fails are hidden, so nothing is named that the owner did not name.
    def resolve_thing(kind, id, viewer = nil, found = nil)
      found ||= {}
      found[[kind.to_s, id]] ||= begin
        k = kinds[kind.to_s]
        v = Visibility.reader(viewer)
        name = k&.label&.call(id, v)
        if name == :gone then [:gone]
        elsif name.is_a?(String) && !name.strip.empty?
          [:shown, name, k.url&.call(id, v).presence, Visibility.mark? ? thing_hidden_from(kind, id) : 0]
        else [:hidden]
        end
      rescue StandardError => e
        Rails.logger.warn("[gk_records] reference kind #{kind} failed on #{id}: #{e.class} #{e.message}") if defined?(Rails)
        [:hidden]
      end
    end

    # What a thing that is gone is called
    def gone_thing_text = ::I18n.t(:text_gk_records_gone_person)

    def thing_text(kind, id, viewer = nil, found = nil, mark: true)
      r = resolve_thing(kind, id, viewer, found)
      case r.first
      when :shown then mark ? r[1] + Visibility.restricted_suffix(r[3]) : r[1]
      when :gone then gone_thing_text
      else Visibility.hidden_text
      end
    end

    def thing_api(kind, id, viewer = nil, found = nil)
      r = resolve_thing(kind, id, viewer, found)
      case r.first
      when :shown
        { THING => kind.to_s, 'id' => id, 'name' => r[1] }.merge(r[3].to_i.positive? ? { 'restricted' => true, 'hidden_from' => r[3] } : {})
      when :gone then { THING => kind.to_s, 'id' => id, 'name' => gone_thing_text, 'deleted' => true }
      else { THING => kind.to_s, 'hidden' => true }
      end
    end

    # The value as text for the viewer: a reference is the name (a list of them the names joined with a comma), a
    # list or hash holding references is said item by item; anything else is its text as before. A person or thing
    # not everyone may see has the short text of the mark after the name (" (syns inte för alla)") unless mark: false.
    def text(v, viewer = nil, found = nil, mark: true)
      return v.to_s unless any?(v)

      found ||= principals(v)
      if one?(v) then name_of(v.values.first, found, viewer, mark: mark)
      elsif many?(v) then v.values.first.map { |id| name_of(id, found, viewer, mark: mark) }.join(', ')
      elsif thing?(v) then thing_text(at(v, THING), at(v, 'id'), viewer, found, mark: mark)
      elsif things?(v) then at(v, 'ids').map { |id| thing_text(at(v, THINGS), id, viewer, found, mark: mark) }.join(', ')
      elsif v.is_a?(Hash) then v.map { |k, x| "#{k}: #{text(x, viewer, found, mark: mark)}" }.join(', ')
      else v.map { |x| text(x, viewer, found, mark: mark) }.join(', ')
      end
    end

    # For REST: a person shown is id and name, a hidden one null with the mark hidden, a gone one its id, core's name
    # and the mark deleted; a thing of a registered kind the same, but a hidden one carries no id at all. One shown
    # whom some other user may not see also carries "restricted" => true and "hidden_from" => N.
    def api(v, viewer = nil, found = nil)
      return v unless any?(v)

      found ||= principals(v)
      one = lambda do |id|
        p = found[id]
        if p.nil? then { ONE => id, 'name' => gone_text, 'deleted' => true }
        elsif Visibility.visible_user?(p, viewer)
          { ONE => id, 'name' => p.name }.merge(Visibility.api_restricted(nil, p, viewer).transform_keys(&:to_s))
        else { ONE => nil, 'hidden' => true }
        end
      end
      if one?(v) then one.call(v.values.first)
      elsif many?(v) then { MANY => v.values.first.map { |id| one.call(id) } }
      elsif thing?(v) then thing_api(at(v, THING), at(v, 'id'), viewer, found)
      elsif things?(v) then { THINGS => at(v, THINGS), 'items' => at(v, 'ids').map { |id| thing_api(at(v, THINGS), id, viewer, found) } }
      elsif v.is_a?(Hash) then v.to_h { |k, x| [k, api(x, viewer, found)] }
      else v.map { |x| api(x, viewer, found) }
      end
    end
  end
end
