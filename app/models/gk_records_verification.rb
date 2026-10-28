# frozen_string_literal: true

# A thing's verification status today (GkRecords::Verification): verified, partly_verified, unverified or hypothesis.
# One row per thing (target_type is the key a plugin registered, as everywhere in records). Changed only through
# Verification.set!, which writes the event; the row is never deleted.
class GkRecordsVerification < ApplicationRecord
  self.table_name = 'gk_records_verifications'
  # an instant with its zone (migration 008)
  GkRecordsInstant.attributes!(self, :set_at)

  belongs_to :set_by, class_name: 'User', optional: true
  validates :target_type, :target_id, :set_at, presence: true
  validates :status, inclusion: { in: ->(_) { GkRecords::Verification::STATUSES + [GkRecords::Verification::NONE] } }
  validates :target_id, uniqueness: { scope: :target_type }
  before_destroy { throw :abort }

  def label = GkRecords::Verification.label(status)
end
