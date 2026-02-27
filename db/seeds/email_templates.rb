# frozen_string_literal: true

# Master seed to load individual email template seed files
Rails.root.glob('db/seeds/email_templates/*.rb').each do |seed_file|
  load seed_file
end

# Seed ES variants from EN templates if they don't already exist.
EmailTemplate.where(locale: 'en').find_each do |en_template|
  EmailTemplate.create_or_find_by!(
    name: en_template.name,
    format: en_template.format,
    locale: 'es'
  ) do |es_template|
    es_template.subject = en_template.subject
    es_template.body = en_template.body
    es_template.description = en_template.description
    es_template.variables = en_template.variables
    es_template.enabled = en_template.enabled
  end
end

Rails.logger.debug 'Finished seeding email templates.' if ENV['VERBOSE_TESTS'] || Rails.env.development?
