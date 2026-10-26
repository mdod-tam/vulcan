# frozen_string_literal: true

# Baseline changes are audited, so each task runs as the system audit administrator inside one transaction.
as_system_actor = lambda do |&work|
  actor = User.system_user || abort('Provision the system audit administrator first with bin/rails db:bootstrap.')
  ActiveRecord::Base.transaction { work.call(actor) }
end

namespace :db do
  desc 'Initialize an environment: validate input, migrate, provision accounts, reset the baseline, and verify. ' \
       'Overwrites staff-edited policies, flags, communication controls, rejection reasons, and every email template.'
  task bootstrap: :environment do
    Baseline::Bootstrap.administrator_input
    Rake::Task['db:migrate'].reenable
    Rake::Task['db:migrate'].invoke
    load Rails.root.join('db/seeds/production.rb')
  end

  desc 'Reset program policies to the checked-in defaults'
  task seed_policies: :environment do
    as_system_actor.call { |actor| Baseline::Policies.reset!(actor: actor) }
    puts "Reset #{Baseline::Policies::DEFAULTS.size} policies to their defaults."
  end

  desc 'Reset feature flags and communication controls to the checked-in defaults'
  task seed_feature_flags: :environment do
    as_system_actor.call { |actor| Baseline::FeatureFlags.reset!(actor: actor) }
    puts "Reset #{Baseline::FeatureFlags::DEFAULTS.size} feature flags to their defaults."
  end

  desc 'Replace every EmailTemplate with the checked-in templates in db/seeds/email_templates'
  task seed_manual_email_templates: :environment do
    count = as_system_actor.call { |actor| EmailTemplates::Catalog.replace!(actor: actor) }
    puts "Replaced all email templates with #{count} checked-in templates."
  end

  desc 'Reset proof and certification rejection reasons to the checked-in bodies'
  task seed_rejection_reasons: :environment do
    as_system_actor.call { |actor| Baseline::RejectionReasons.reset!(actor: actor) }
    puts "Reset #{Baseline::RejectionReasons::DEFINITIONS.size * Baseline::RejectionReasons::LOCALES.size} rejection reasons to their checked-in bodies."
  end
end
