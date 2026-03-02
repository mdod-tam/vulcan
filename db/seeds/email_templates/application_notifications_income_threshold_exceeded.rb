# frozen_string_literal: true

# Seed File for "application_notifications_income_threshold_exceeded"
# (Suggest saving as db/seeds/email_templates/application_notifications_income_threshold_exceeded.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_income_threshold_exceeded', format: :text) do |template|
  template.subject = 'Important Information About Your MAT Application'
  template.description = 'Sent when an application is rejected because income exceeds the eligibility threshold.'
  template.body = <<~TEXT
    %<header_text>s

    Important Information About Your MAT Application

    Dear %<constituent_first_name>s,

    We have reviewed your application for the Maryland Accessible Telecommunications program.

    APPLICATION REJECTED

    Unfortunately, we are unable to approve your application at this time because your reported annual income exceeds our program's eligibility threshold.

    Your household size: %<household_size>s
    Your reported annual income: %<annual_income_formatted>s
    Maximum income threshold for your household size: %<threshold_formatted>s

    %<additional_notes>s

    If your financial situation changes, or if you believe this determination was made in error, you may submit a new application with updated information.

    If you have any questions or need assistance, please contact our support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name annual_income_formatted household_size threshold_formatted footer_text],
    'optional' => %w[additional_notes]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_income_threshold_exceeded (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
