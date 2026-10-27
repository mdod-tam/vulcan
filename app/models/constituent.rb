# frozen_string_literal: true

# Top-level +Constituent+ alias for +Users::Constituent+.
require_dependency 'users/constituent'

Constituent = Users::Constituent unless defined?(Constituent)
