# frozen_string_literal: true

if Rails.env.test? && Rake::Task.task_defined?('assets:precompile')
  # Propshaft serves the built application.js, so build the JavaScript before precompiling assets in test.
  Rake::Task['assets:precompile'].enhance(['javascript:build'])
end
