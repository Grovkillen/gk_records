# frozen_string_literal: true

# Added in 1.01.000, after the merge at 1.00.000: Se händelser moved into the project module Händelser. An installation
# that gave a role the permission keeps what it had: the module is turned on in every active project where a member
# has such a role, and in every active public project when Non member or Anonymous has it. No role is changed.
# Down leaves the modules on: a module turned on is a setting the projects keep.
class EnableGkRecordsEventsModule < ActiveRecord::Migration[6.1]
  def up
    roles = Role.all.select { |r| Array(r.permissions).map(&:to_sym).include?(:gk_records_view_events) }
    return if roles.empty?

    # Non member and Anonymous are core's built-in roles (builtin not 0)
    builtin = roles.any? { |r| r.builtin.to_i != 0 }
    Project.where(status: Project::STATUS_ACTIVE).find_each do |project|
      next if project.enabled_module_names.include?('gk_records_events')

      member = MemberRole.joins(:member).where(members: { project_id: project.id }, role_id: roles.map(&:id)).exists?
      next unless member || (builtin && project.is_public?)

      EnabledModule.create!(project_id: project.id, name: 'gk_records_events')
    end
  end

  def down; end
end
