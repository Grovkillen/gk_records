# frozen_string_literal: true

# A reading: one import or sync run, made by GkRecords::Readings. It keeps facts about the files it read, never the
# files: their names, sizes and SHA-256 (files_json), the mapping that turned them into posts, when the source's files
# were fetched and the source's manifest trimmed to the keys that describe the source. Never deleted (P1); finish!
# sets the counts.
# Who may see it: administrators, and those who may see what it read into (the registered target of its target_type,
# asked on an object a field of which points to it).
class GkRecordsReading < ApplicationRecord
  self.table_name = 'gk_records_readings'
  # instants with their zone: the source's time often comes with an offset of its own
  GkRecordsInstant.attributes!(self, :source_time, :read_at, :retrieved_at)

  ROUTES = %w[file api odbc hand].freeze
  MODES = %w[locked passive manual_wins proposal on_call once].freeze

  belongs_to :user, optional: true
  belongs_to :origin_reading, class_name: 'GkRecordsReading', optional: true
  has_many :field_origins, class_name: 'GkRecordsFieldOrigin', foreign_key: :reading_id

  validates :source_label, presence: true, length: { maximum: 200 }
  validates :route, inclusion: { in: ROUTES }
  validates :mode, inclusion: { in: MODES }
  validates :format, length: { maximum: 20 }
  validates :source_ref, length: { maximum: 200 }
  validates :account, length: { maximum: 100 }
  validates :mapping, length: { maximum: 80 }, format: { with: /\A[\w.\-]+@[\w.\-]+\z/ }, allow_nil: true
  before_destroy { throw :abort }

  scope :sorted, -> { order(read_at: :desc, id: :desc) }

  def project = nil

  def counts = (JSON.parse(counts_json.presence || '{}') rescue {})
  def manifest = (JSON.parse(manifest_json.presence || 'null') rescue nil)
  # What the reader chose to read of the files: { "by", "path", "values", "labels" }, or nil
  def selection = (JSON.parse(selection_json.presence || 'null') rescue nil)

  # The files read: [{ 'file', 'size', 'sha256' }], empty for a sync or a reading made in hindsight
  def files
    list = JSON.parse(files_json.presence || '[]')
    list.is_a?(Array) ? list : []
  rescue JSON::ParserError
    []
  end

  # An object a field of which points to this reading (for the visibility test), or nil
  def a_target
    o = field_origins.order(:id).first
    t = o && GkRecords::Targets.find(o.target_type)
    t&.model_class&.find_by(id: o.target_id)
  end

  def visible?(user = User.current)
    return true if user.admin?

    t = GkRecords::Targets.find(target_type)
    return false unless t

    !!t.visible.call(a_target, user)
  rescue StandardError
    false
  end

  def to_s = GkRecords::Readings.label(self)
end
