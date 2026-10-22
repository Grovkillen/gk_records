# frozen_string_literal: true

# Shared for the records controllers: the target from "key:id", and who may see and write it (the owner's rules)
class GkRecordsBaseController < ApplicationController
  before_action :require_login

  private

  def find_target(ref = params[:target])
    pair = GkRecords::Targets.resolve(ref)
    return render_404 unless pair

    @target_def, @target = pair
    deny_access unless GkRecords::Targets.visible?(@target)
  end

  def require_editable
    deny_access unless GkRecords::Targets.editable?(@target)
  end

  # The start of a day as the reader counts it (her time zone, else the server's), as core's date filters do;
  # Date#beginning_of_day is in Rails' own zone, which is UTC in Redmine
  def day_start(date)
    zone = User.current.time_zone
    zone ? zone.local(date.year, date.month, date.day) : Time.local(date.year, date.month, date.day)
  end

  def day_end(date) = day_start(date).end_of_day

  def back_to_target(anchor = 'gk-records')
    url = GkRecords::Targets.url(@target)
    redirect_back_or_default(url ? url_for(url.merge(anchor: anchor)) : home_url)
  end
end
