# frozen_string_literal: true

# export_log: a print asked for in the browser (the script on every page tells when printing starts); written as the
# event printed on what the page shows (GkRecords::ExportLog.printed!). Only for one who is logged in; answers
# 204 whatever happened, so the page never waits on it.
# The one records controller without the gate to GK GUI Stuff (gate.rb): a print asked for is trace, so the address
# answers also while the gate is closed. It draws nothing and uses nothing of GK GUI Stuff.
class GkRecordsPrintsController < ApplicationController
  before_action :require_login

  def create
    GkRecords::ExportLog.printed!(params[:path].to_s, request)
    head :no_content
  end
end
