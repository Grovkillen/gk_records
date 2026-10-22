# frozen_string_literal: true

# The administrator's mode for the reasons (GkRecords::Reasons): one row for the installation (key '*') and one per
# place that does not follow it. Changed only through Reasons.set_mode!, which writes the event.
class GkRecordsReasonMode < ApplicationRecord
  self.table_name = 'gk_records_reason_modes'

  validates :key, presence: true, uniqueness: true
  validates :mode, presence: true

  def place_label
    key == GkRecords::Reasons::ALL ? ::I18n.t(:label_gk_records_reasons_installation) : (GkRecords::Reasons.find(key)&.label || key)
  end
end
