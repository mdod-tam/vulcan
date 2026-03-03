# frozen_string_literal: true

# Master seed to load individual email template seed files
Rails.root.glob('db/seeds/email_templates/*.rb').each do |seed_file|
  load seed_file
end

Rails.logger.debug 'Finished seeding email templates.' if ENV['VERBOSE_TESTS'] || Rails.env.development?
