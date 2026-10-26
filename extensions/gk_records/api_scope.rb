# frozen_string_literal: true

module GkRecords
  # OAuth token scopes on the REST API, through gk_compat when it is there (it is optional). A scope only limits: who may
  # do something is still the caller's own check (the login, the admin flag, a role). Without gk_compat core's own
  # checks apply, as before.
  module ApiScope
    module_function

    # Read the kinds, and the administrators' lists of readings and reasons
    READ = :gk_records_api_read
    # Change the reason modes
    MANAGE = :gk_records_api_manage

    # True without a token; with a token only when it has the permission
    def allows?(user, permission)
      defined?(::GkCompat) ? ::GkCompat.call(:scope_allows?, user, permission) : true
    end

    # The account is an administrator and the token, if any, has the permission (or :admin)
    def admin_allows?(user, permission)
      defined?(::GkCompat) ? ::GkCompat.call(:admin_allows?, user, permission) : user.admin?
    end

    # Project.allowed_to_condition with the token's scopes
    def project_condition(user, permission, options = {}, &block)
      return ::GkCompat.call(:project_condition, user, permission, options, &block) if defined?(::GkCompat)

      Project.allowed_to_condition(user, permission, options, &block)
    end
  end
end
