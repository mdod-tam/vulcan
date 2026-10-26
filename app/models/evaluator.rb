# frozen_string_literal: true

# Top-level +Evaluator+ alias for +Users::Evaluator+.
require_dependency 'users/evaluator'

Evaluator = Users::Evaluator unless defined?(Evaluator)
