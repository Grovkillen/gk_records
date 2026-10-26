# frozen_string_literal: true

class GkRecordsKindsController < GkRecordsBaseController
  accept_api_auth :index
  # who may stays any signed-in person; an OAuth token needs the read scope
  before_action -> { render_403 unless GkRecords::ApiScope.allows?(User.current, GkRecords::ApiScope::READ) }

  # Direction: a link kind is symmetric or directed (Kind has no direction of its own); person_fields: the detail fields
  # an event kind declared as holding people; targets and sources of a link kind (null: any thing) and private_fields of
  # an event kind (shown only to a reader who may see the target); the assessment kinds that are data too, with their
  # scale (null for the registered ones)
  def index
    render json: { kinds: GkRecords::Kinds.listed.map { |k|
      { scope: k.scope, key: k.key, plugin: k.plugin, label: k.label, direction: k.scope == 'link' ? (k.symmetric ? 'symmetric' : 'directed') : nil,
        person_fields: k.person_fields, targets: k.scope == 'link' ? k.targets : nil, sources: k.scope == 'link' ? k.sources : nil,
        private_fields: k.private_fields || [], scale: k.scale&.map { |v| { key: v['key'], label: k.scale_label(v['key']) } } }
    } }
  end
end
