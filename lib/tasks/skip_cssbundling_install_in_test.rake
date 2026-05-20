# frozen_string_literal: true

if Rails.env.test? && Rake::Task.task_defined?('css:build')
  require 'fileutils'

  # In test we only need the compiled stylesheet, not a fresh dependency
  # installation on every run. Using the local binary avoids invoking
  # css:install -> yarn install during test:prepare, which has been brittle in
  # local environments even when node_modules is already present.
  Rake::Task['css:build'].clear_prerequisites
  Rake::Task['css:build'].clear_actions
  Rake::Task['css:build'].enhance do
    tailwind = Rails.root.join('node_modules/.bin/tailwindcss')
    abort "Missing Tailwind binary at #{tailwind}; run yarn install first." unless tailwind.exist?

    FileUtils.mkdir_p(Rails.root.join('app/assets/builds'))

    sh tailwind.to_s,
       '-i', Rails.root.join('app/assets/stylesheets/application.tailwind.css').to_s,
       '-o', Rails.root.join('app/assets/builds/application.css').to_s,
       '--minify'
  end
end
