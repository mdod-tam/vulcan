# frozen_string_literal: true

if Rails.env.test? && Rake::Task.task_defined?('assets:precompile')
  # Ensure JS is built in test so application.js exists for Sprockets lookup
  Rake::Task['assets:precompile'].enhance(['javascript:build'])
end
