# frozen_string_literal: true

require 'securerandom'

module GkRecords
  # The global identity of every thing records knows. 1. It lives in records' table gk_records_identities, for every
  # registered target (core's things and ours); no column in core. A new sort of thing gets identities by being
  # registered (Targets.register installs the hook). 2. The global id (gid) is a UUID version 7: time first, unique
  # without coordination, sortable. The instance stands beside it as origin, never in it, so the gid follows the thing
  # when a part becomes an instance of its own. 3. The instance's own id is written by create_instance.ps1 in the
  # instance's INSTANCE.yml (instance_id, a UUID version 7, and instance_name); records reads it (Identity.instance_id).
  # 4. Origin and owner are two facts: the origin instance stands for ever; the owner is the instance that owns the
  # thing now and changes only as an event (change_owner!, event owner_changed). The gid never changes. 5. Instances
  # made before this have no instance id: only an instance_id that is a UUID version 7 counts (the older instance_id in
  # INSTANCE.yml is a version 4 the environment's authority uses, and is not this identity). 6. A thing still gets its
  # gid at once; origin and owner stay empty until the instance has an id, and are filled in then (fill_origin!, at
  # boot), never changing an origin already set.
  # Things made before the table existed, and things a scenario keeps when it empties the instance (accounts, settings),
  # get theirs from backfill!, at boot and at the start of records' scenario step. Nothing here is ever deleted.
  module Identity
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    UUID7 = /\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/i
    EVENT = 'owner_changed'
    TABLE = 'gk_records_identities'
    BATCH = 1000

    # Included in every registered target's model: after_create gives the new thing its identity, in the same
    # transaction (a savepoint, so a fault here never stops the thing itself from being made; the backfill mends it)
    module Hook
      def self.included(base)
        base.after_create(:gk_records_identity_assign)
      end

      private

      def gk_records_identity_assign
        ::GkRecords::Identity.assign(self)
      end
    end

    module_function

    # A new UUID version 7 as lower case text: 48 bits of Unix milliseconds, version 7, variant 10, the rest random
    def uuid7(at = Time.current)
      ms = (at.to_r * 1000).to_i
      b = SecureRandom.random_bytes(16).bytes
      6.times { |i| b[i] = (ms >> (8 * (5 - i))) & 0xff }
      b[6] = (b[6] & 0x0f) | 0x70
      b[8] = (b[8] & 0x3f) | 0x80
      h = b.pack('C*').unpack1('H*')
      "#{h[0, 8]}-#{h[8, 4]}-#{h[12, 4]}-#{h[16, 4]}-#{h[20, 12]}"
    end

    def uuid7?(value) = UUID7.match?(value.to_s)

    def instance_file
      ENV['GK_INSTANCE_FILE'].presence || Rails.root.join('..', 'INSTANCE.yml').to_s
    end

    def instance_data
      @instance_data ||= begin
        text = File.file?(instance_file) ? File.read(instance_file, encoding: 'UTF-8') : ''
        %w[instance_id instance_name instance dump].to_h { |k| [k, text[/^#{k}:[ \t]*"?([^"\r\n]*)"?[ \t]*$/, 1].to_s.strip] }
      rescue StandardError
        {}
      end
    end

    # The instance's id, or nil when it has none: no file, no instance_id, or one that is not a version 7
    def instance_id
      v = instance_data['instance_id'].to_s.downcase
      uuid7?(v) ? v : nil
    end

    def instance_name = instance_data['instance_name'].presence || (instance_id && instance_data['instance'].presence)

    # An instance made from a dump (INSTANCE.yml dump) did not make what came with the dump: it gives the things it makes
    # itself its id as origin, never those it only found (backfill!, fill_origin!, and an identity made on first use)
    def from_dump? = instance_data['dump'].present?
    def claim_origin = from_dump? ? nil : instance_id

    # Read the file again (a test, or after the file was written while the process ran)
    def reset!
      @instance_data = nil
      @ready = nil
    end

    def ready?
      @ready ||= ::ActiveRecord::Base.connection.data_source_exists?(TABLE)
    rescue StandardError
      false
    end

    # The hook on a target's model (from Targets.register, and for every target again when init.rb runs after a code
    # reload). A model that cannot be found yet, is no Active Record model or cannot take callbacks is passed over and
    # tried again at the next call; a model that has the hook, itself or through its parent, is left as it is.
    def install(model)
      klass = model.is_a?(Class) ? model : model.to_s.safe_constantize
      return false unless klass.is_a?(Class) && klass < ::ActiveRecord::Base && !klass.abstract_class? && klass.respond_to?(:after_create)
      return true if klass < Hook

      klass.include(Hook)
      true
    rescue StandardError => e
      Rails.logger&.warn("[gk_records] identity hook on #{model}: #{e.class} #{e.message}")
      false
    end

    def install_all! = Targets.all.values.map(&:model).uniq.each { |m| install(m) }

    # The target a thing is: its own class registered, else the nearest registered class above it (an anonymous user
    # is a user); nil when it is none
    def target_of(obj)
      return nil if obj.nil?

      Targets.for_object(obj) || Targets.all.values.detect do |t|
        k = t.model.safe_constantize
        k.is_a?(Class) && obj.is_a?(k)
      end
    end

    # after_create: the new thing's identity, origin and owner this instance (nil until it has an id)
    def assign(obj)
      return nil unless ready? && obj.id.is_a?(Integer)

      t = target_of(obj) or return nil
      make_row(t.key, obj.id, instance_id)
    rescue StandardError => e
      Rails.logger&.warn("[gk_records] identity for #{obj.class.name} #{obj.id}: #{e.class} #{e.message}")
      nil
    end

    # One row in a savepoint; when another process made it first, that row
    def make_row(key, id, origin)
      ::GkRecordsIdentity.transaction(requires_new: true) do
        ::GkRecordsIdentity.create!(target_type: key.to_s, target_id: id, gid: uuid7, origin_instance: origin, owner_instance: origin,
                                 created_at: Time.current)
      end
    rescue ::ActiveRecord::RecordNotUnique
      ::GkRecordsIdentity.for_target(key, id).first
    end

    # A thing's row, made when it is missing (first use); nil for what is no registered target or has no id yet
    def row(obj)
      t = obj&.id && target_of(obj) or return nil
      return nil unless ready?

      ::GkRecordsIdentity.for_target(t.key, obj.id).first || make_row(t.key, obj.id, claim_origin)
    end

    # The thing's gid (made when missing)
    def for(obj) = row(obj)&.gid

    # The target key a model is registered under (the one Targets.for_object finds), or nil
    def key_for(model_name) = Targets.all.values.detect { |t| t.model == model_name.to_s }&.key

    # { id => gid } for many things of one target, the missing ones made at once
    def gids_for(key, ids)
      return {} if key.blank?

      ids = Array(ids).compact.map(&:to_i).uniq
      return {} if ids.empty? || !ready?

      have = ::GkRecordsIdentity.where(target_type: key.to_s, target_id: ids).pluck(:target_id, :gid).to_h
      missing = ids - have.keys
      if missing.any?
        insert_rows(key, missing, claim_origin)
        have.merge!(::GkRecordsIdentity.where(target_type: key.to_s, target_id: missing).pluck(:target_id, :gid).to_h)
      end
      have
    end

    # The thing a gid names, or nil (no such gid, its target no longer registered, or the thing gone)
    def find(gid)
      r = find_row(gid) or return nil
      t = Targets.find(r.target_type) or return nil
      t.model_class.find_by(id: r.target_id)
    end

    def find_row(gid)
      g = gid.to_s.strip.downcase
      UUID.match?(g) ? ::GkRecordsIdentity.find_by(gid: g) : nil
    end

    # Answer 4: the owner changes, as an event on the thing with the reason; the origin and the gid never change. Returns
    # the event, or nil when the thing has that owner already. new_instance is another instance's id (a UUID).
    def change_owner!(obj, new_instance, reason:, user: User.current, origin: 'human')
      to = new_instance.to_s.strip.downcase
      raise ArgumentError, "owner instance #{new_instance.inspect} is not a UUID" unless UUID.match?(to)
      raise ArgumentError, 'a change of owner needs a reason' if reason.to_s.strip.empty?
      raise ArgumentError, "#{obj.class.name} is not a registered records target" unless target_of(obj)

      event = nil
      ::GkRecordsIdentity.transaction do
        r = row(obj) or raise ArgumentError, "#{obj.class.name} #{obj.id} has no identity"
        r.lock!
        from = r.owner_instance.presence
        unless from == to
          r.update!(owner_instance: to)
          event = Events.write(obj, EVENT, details: { 'gid' => r.gid, 'owner_instance' => [from, to] }, reason: reason.to_s.strip,
                                           user: user, origin: origin)
        end
      end
      event
    end

    # Answer 6: once the instance has an id, the rows with an empty origin get it, and an empty owner beside it; an
    # origin already set is never touched. Idempotent; not in an instance made from a dump. Returns how many origins.
    def fill_origin!
      id = claim_origin
      return 0 unless id && ready?

      n = ::GkRecordsIdentity.where(origin_instance: [nil, '']).update_all(origin_instance: id)
      ::GkRecordsIdentity.where(owner_instance: [nil, ''], origin_instance: id).update_all(owner_instance: id)
      n
    end

    # Every registered target's things without an identity get one, in batches; running it again makes nothing. One
    # target per model (the one Targets.for_object finds). A target whose model or table is not there is passed over.
    # Returns how many were made.
    def backfill!(batch: BATCH)
      return 0 unless ready?

      origin = claim_origin
      Targets.all.values.uniq(&:model).sum do |t|
        backfill_target(t, origin, batch)
      rescue StandardError => e
        Rails.logger&.warn("[gk_records] identity backfill of #{t.key}: #{e.class} #{e.message}")
        0
      end
    end

    def backfill_target(target, origin, batch)
      klass = target.model.safe_constantize
      return 0 unless klass.is_a?(Class) && klass < ::ActiveRecord::Base && !klass.abstract_class? && klass.table_exists?

      made = 0
      loop do
        have = ::GkRecordsIdentity.where(target_type: target.key).select(:target_id)
        ids = klass.unscoped.where.not(id: have).order(:id).limit(batch).pluck(:id)
        break if ids.empty?

        before = ::GkRecordsIdentity.where(target_type: target.key).count
        insert_rows(target.key, ids, origin)
        added = ::GkRecordsIdentity.where(target_type: target.key).count - before
        made += added
        break if added <= 0 # nothing could be added: never loop on the same rows
      end
      made
    end

    # Many rows at once; a row another process made first is left as it is (ON CONFLICT DO NOTHING)
    def insert_rows(key, ids, origin)
      now = Time.current
      rows = ids.map { |id| { target_type: key.to_s, target_id: id, gid: uuid7(now), origin_instance: origin, owner_instance: origin, created_at: now } }
      ::GkRecordsIdentity.insert_all(rows) if rows.any?
    end

    # At boot (init.rb, after initialize): the hooks, the origin filled in, the backfill. Not under rake (migrations run
    # there before the table may exist) and once per process; a fault is logged, never raised.
    def boot!
      return if @booted
      return if defined?(::Rake.application) && ::Rake.application.respond_to?(:top_level_tasks) && ::Rake.application.top_level_tasks.any?

      install_all!
      return unless ready?

      @booted = true
      filled = fill_origin!
      made = backfill!
      Rails.logger&.info("[gk_records] identities: #{made} made, #{filled} origins filled in (instance #{instance_id || '-'})") if made.positive? || filled.positive?
    rescue StandardError => e
      Rails.logger&.warn("[gk_records] identities at boot: #{e.class} #{e.message}")
    end
  end
end
