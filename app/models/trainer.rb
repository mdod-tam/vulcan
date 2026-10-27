# frozen_string_literal: true

# Top-level +Trainer+ alias for +Users::Trainer+.
require_dependency 'users/trainer'

Trainer = Users::Trainer unless defined?(Trainer)
