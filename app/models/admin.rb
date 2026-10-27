# frozen_string_literal: true

# Top-level +Administrator+ alias for +Users::Administrator+. The +Admin+ module that namespaces
# Admin::BaseController and the other admin classes comes from config/initializers/001_admin_namespace.rb.
require_dependency 'users/administrator'

Administrator = Users::Administrator unless defined?(Administrator)
