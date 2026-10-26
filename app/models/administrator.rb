# frozen_string_literal: true

# Top-level +Administrator+ alias for +Users::Administrator+.
require_dependency 'users/administrator'

Administrator = Users::Administrator unless defined?(Administrator)
