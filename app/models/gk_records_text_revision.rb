# frozen_string_literal: true

# One revision of one cell of the system texts: a locale key in one locale, the template as the locale file had it from
# valid_from, and its SHA-256. A row is added only when the cell's text changed; never changed, never deleted (history
# is not rewritten).
class GkRecordsTextRevision < ApplicationRecord
  self.table_name = 'gk_records_text_revisions'
  # instants with their zone (migration 013)
  GkRecordsInstant.attributes!(self, :valid_from, :created_at)

  validates :key, :locale, :sha256, :valid_from, presence: true
  validates :body, exclusion: { in: [nil] }
  before_update { throw :abort }
  before_destroy { throw :abort }
end
