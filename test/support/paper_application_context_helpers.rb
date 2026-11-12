# frozen_string_literal: true

# Context setup for paper application tests.
module PaperApplicationContextHelpers
  def create_paper_no_email_constituent(phone:, phone_type:, first_name:, last_name:)
    Current.paper_context = true
    Users::Constituent.create!(
      first_name: first_name, last_name: last_name, phone: phone, phone_type: phone_type,
      communication_preference: :letter,
      physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
      date_of_birth: Date.new(1950, 1, 1), password: 'password1234', password_confirmation: 'password1234',
      hearing_disability: true
    )
  ensure
    Current.reset
  end

  def setup_paper_application_context
    Thread.current[:paper_application_context] = true
    Current.paper_context = true

    # Ensure the single workflow feature flag exists with its default so that
    # stamp_workflow_defaults! and scrub_income_fields behave correctly.
    FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = false }
  end

  def teardown_paper_application_context
    Thread.current[:paper_application_context] = nil
    Current.reset if defined?(Current) && Current.respond_to?(:reset)
  end

  def paper_application_context?
    Thread.current[:paper_application_context] || Current.paper_context
  end
end
