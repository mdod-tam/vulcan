# frozen_string_literal: true

# Paper Application Test Helper
#
# Simplified helper module for paper application system tests.
# This module provides basic form interaction helpers that work with
# the centralized ApplicationSystemTestCase infrastructure.
module PaperApplicationsTestHelper
  # Helper methods for filling out paper application forms

  def fill_in_applicant_information(first_name: 'John', last_name: 'Doe', email: nil, phone: '555-123-4567', date_of_birth: '1980-01-15')
    email ||= "#{first_name.downcase}.#{last_name.downcase}.#{Time.now.to_i}@example.com"

    within_applicant_fieldset do
      # Use explicit field clearing for critical fields that might be reused
      find('input[name="constituent[first_name]"]').set('').set(first_name)
      find('input[name="constituent[last_name]"]').set('').set(last_name)
      find('input[name="constituent[email]"]').set('').set(email)
      find('input[name="constituent[phone]"]').set('').set(phone)
      # Date of birth is required
      find('input[name="constituent[date_of_birth]"]').set(date_of_birth)
    end
  end

  def fill_in_application_details(household_size: 2, annual_income: 30_000)
    within_application_details_fieldset do
      # Clear and set field values explicitly to avoid concatenation issues
      household_size_field = find('input[name="application[household_size]"]')
      household_size_field.set('') # Clear first
      household_size_field.set(household_size.to_s)

      income_field = find('input[name="application[annual_income]"]')
      income_field.set('') # Clear first
      income_field.set(annual_income.to_s)

      check 'application[maryland_resident]'
    end
  end

  def fill_in_disability_information
    within_disability_fieldset do
      check 'applicant_attributes[self_certify_disability]'
      check 'applicant_attributes[hearing_disability]'
    end
  end

  def fill_in_medical_provider_information(name: 'Dr. Smith', phone: '555-987-6543', email: 'dr.smith@example.com')
    within_medical_provider_fieldset do
      # Clear and set field values explicitly to avoid concatenation issues
      find('input[name="application[medical_provider_name]"]').set('').set(name)
      find('input[name="application[medical_provider_phone]"]').set('').set(phone)
      find('input[name="application[medical_provider_email]"]').set('').set(email)
    end
  end

  def attach_and_accept_proofs
    within_proof_documents_fieldset do
      # Income proof
      choose 'accept_income_proof'
      attach_file 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')

      # Residency proof
      choose 'accept_residency_proof'
      attach_file 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
    end
  end

  # Fieldset helper methods
  def within_applicant_fieldset(&)
    within find('fieldset', text: "Applicant's Information"), &
  end

  def within_application_details_fieldset(&)
    within find('fieldset', text: 'Proof Documents'), &
  end

  def within_disability_fieldset(&)
    within find('fieldset', text: 'Disability Information'), &
  end

  def within_medical_provider_fieldset(&)
    within find('fieldset', text: 'Medical Provider Information'), &
  end

  def within_proof_documents_fieldset(&)
    within find('fieldset', text: 'Proof Documents'), &
  end

  # Utility methods for common test actions
  def safe_visit(path)
    visit(path)
    wait_for_network_idle
  end

  def safe_interaction(&block) # rubocop:disable Naming/BlockForwarding,Style/ArgumentsForwarding
    using_wait_time(Capybara.default_max_wait_time, &block) # rubocop:disable Naming/BlockForwarding,Style/ArgumentsForwarding
  rescue Capybara::ElementNotFound => e
    puts "Element interaction failed: #{e.message}, retrying after DOM stabilized"
    wait_until_dom_stable if respond_to?(:wait_until_dom_stable)
    using_wait_time(Capybara.default_max_wait_time, &block) # rubocop:disable Naming/BlockForwarding,Style/ArgumentsForwarding
  end

  def measure_time(description)
    start_time = Time.current
    yield
    elapsed = Time.current - start_time
    puts "#{description} took #{elapsed.round(2)} seconds" if ENV['VERBOSE_TESTS']
  end

  # Simple field filling that tries multiple approaches with proper clearing
  def paper_fill_in(field_label, value)
    # Try standard approach with explicit clearing first
    field = find_field(field_label)
    field.set('').set(value)
  rescue Capybara::ElementNotFound
    # Try by name attribute as fallback
    case field_label
    when 'Household Size'
      find('input[name="application[household_size]"]').set('').set(value)
    when 'Annual Income'
      find('input[name="application[annual_income]"]').set('').set(value)
    else
      # Try find by partial text match and clear first
      field = find_field(field_label, match: :first)
      field.set('').set(value)
    end
  end
end
