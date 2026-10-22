# frozen_string_literal: true

# An instant with its zone. Redmine writes times as the server's local time without an offset (default_timezone
# local); into a timestamptz column the database would then read them in its own session's zone, which need not be
# the server's. This type writes every instant in UTC with the offset written out, so what is kept never depends on
# a zone, and reads the offset the database sends back. The same as timetrack's, kept here so that records needs
# no other plugin.
class GkRecordsInstant < ActiveRecord::Type::DateTime
  def serialize(value)
    v = super
    v.respond_to?(:utc) ? self.class.text(v) : v
  end

  # "2025-10-25 23:30:00.000000+00:00": for a model's attribute and for a time compared in SQL
  # (getutc, not utc: utc would turn the caller's Time itself into UTC)
  def self.text(time) = time.getutc.strftime('%Y-%m-%d %H:%M:%S.%6N+00:00')

  # The plugin's own time columns, per model
  def self.attributes!(model, *names) = names.each { |n| model.attribute(n, new) }
end
