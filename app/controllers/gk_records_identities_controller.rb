# frozen_string_literal: true

#   GET /gk_records/identities/<gid>.json
# { identity: { gid, type, id, url, origin_instance, owner_instance, owned_here, created_at }, instance: { id, name } }.
# The thing's own visibility applies: a gid that is unknown, whose thing is gone or that the reader may not see answers
# 404 alike, so the answer never tells that a hidden thing exists.
class GkRecordsIdentitiesController < GkRecordsBaseController
  accept_api_auth :show

  def show
    row = GkRecords::Identity.find_row(params[:gid])
    obj = row && GkRecords::Identity.find(row.gid)
    return render_404 unless obj && GkRecords::Targets.visible?(obj)

    here = GkRecords::Identity.instance_id
    render json: {
      identity: { gid: row.gid, type: row.target_type, id: row.target_id, url: absolute_url(obj),
                  origin_instance: row.origin_instance.presence, owner_instance: row.owner_instance.presence,
                  owned_here: here.present? && row.owner_instance == here, created_at: row.created_at },
      instance: { id: here, name: GkRecords::Identity.instance_name }
    }
  end

  private

  # The thing's page as a full address (the owner's url is a route hash or a path), or nil when it has none
  def absolute_url(obj)
    u = GkRecords::Targets.url(obj)
    case u
    when Hash then url_for(u.merge(only_path: false))
    when String then u.start_with?('/') ? "#{request.base_url}#{u}" : u
    end
  rescue StandardError
    nil
  end
end
