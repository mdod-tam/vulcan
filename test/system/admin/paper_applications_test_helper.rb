# frozen_string_literal: true

# Paper Application Test Helper
#
# Simplified helper module for paper application system tests.
# This module provides basic form interaction helpers that work with
# the centralized ApplicationSystemTestCase infrastructure.
module PaperApplicationsTestHelper
  # Helper methods for filling out paper application forms

  def fill_in_applicant_information(first_name: 'John', last_name: 'Doe', email: nil, phone: '555-123-4567', date_of_birth: '01/15/1980')
    email ||= "#{first_name.downcase}.#{last_name.downcase}.#{Time.now.to_i}@example.com"

    within_applicant_fieldset do
      # Use explicit field clearing for critical fields that might be reused
      find('input[name="constituent[first_name]"]').set('').set(first_name)
      find('input[name="constituent[last_name]"]').set('').set(last_name)
      find('input[name="constituent[email]"]').set('').set(email)
      find('input[name="constituent[phone]"]').set('').set(phone)
      # Date of birth is required
      find('input[name="constituent[date_of_birth]"]').set(date_of_birth)
      find('input[name="constituent[physical_address_1]"]').set('').set('123 Main St')
      find('input[name="constituent[city]"]').set('').set('Baltimore')
      find('input[name="constituent[state]"]').set('').set('MD')
      find('input[name="constituent[zip_code]"]').set('').set('21201')
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
    attach_file 'medical_certification', Rails.root.join('test/fixtures/files/medical_certification_valid.pdf')

    within_proof_documents_fieldset do
      # Income proof
      choose 'accept_income_proof', allow_label_click: true
      attach_file 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')

      # Residency proof
      choose 'accept_residency_proof', allow_label_click: true
      attach_file 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

      # ID proof
      choose 'accept_id_proof', allow_label_click: true
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
    end
  end

  def complete_paper_application_attestations
    check 'application[terms_accepted]' if page.has_unchecked_field?('application[terms_accepted]', wait: 1)
    check 'application[medical_release_authorized]' if page.has_unchecked_field?('application[medical_release_authorized]', wait: 1)
    check 'application[information_verified]' if page.has_unchecked_field?('application[information_verified]', wait: 1)
    sync_paper_submit_gate
  end

  def sync_paper_submit_gate
    page.execute_script(<<~JS)
      const form = document.querySelector('form[data-controller~="paper-application"]');
      if (form) {
        form.dispatchEvent(new CustomEvent('income-validation:validated', {
          bubbles: true,
          detail: { exceedsThreshold: false }
        }));
        form.dispatchEvent(new Event('change', { bubbles: true }));
        form.dispatchEvent(new Event('input', { bubbles: true }));
      }
    JS
  end

  # Fieldset helper methods
  def within_applicant_fieldset(&)
    reveal_adult_application_sections
    within find_by_id('self-info-section'), &
  end

  def within_application_details_fieldset(&)
    within_proof_documents_fieldset(&)
  end

  def within_disability_fieldset(&)
    within find('fieldset', text: 'Disability Information'), &
  end

  def within_medical_provider_fieldset(&)
    within find('fieldset', text: 'Certifying Professional Information'), &
  end

  def within_proof_documents_fieldset(&)
    reveal_paper_application_common_sections
    within find('section', text: 'Proof Documents'), &
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

  def reveal_adult_application_sections
    click_button 'Create New Applicant' if page.has_button?('Create New Applicant', wait: 1)

    reveal_paper_application_common_sections

    page.execute_script(<<~JS)
      const adultSearchSection = document.querySelector('[data-applicant-type-target="adultSearchSection"]');
      const adultSection = document.querySelector('[data-applicant-type-target="adultSection"]');

      [adultSearchSection, adultSection].forEach((section) => {
        if (!section) return;
        section.hidden = false;
        section.classList.remove('hidden');
        section.style.display = 'block';
        section.querySelectorAll('input, select, textarea, button').forEach((field) => {
          field.disabled = false;
        });
      });
    JS
  end

  def reveal_paper_application_common_sections
    page.execute_script(<<~JS)
      const commonSections = document.querySelector('[data-applicant-type-target="commonSections"]');
      const proofSection = document.querySelector('#proof-heading')?.closest('section');
      const incomeFieldsContainer = document.querySelector('[data-income-validation-target="incomeFieldsContainer"]');

      [commonSections, proofSection, incomeFieldsContainer].forEach((section) => {
        if (!section) return;
        section.hidden = false;
        section.classList.remove('hidden');
        section.style.display = 'block';
        section.querySelectorAll('input, select, textarea, button').forEach((field) => {
          field.disabled = false;
        });
      });

      ['application[household_size]', 'application[annual_income]', 'income_proof', 'residency_proof', 'id_proof'].forEach((name) => {
        const field = document.querySelector(`[name="${name}"]`);
        let node = field;
        while (node && node !== document.body) {
          node.hidden = false;
          node.classList?.remove('hidden');
          if (node.style) node.style.display = node.tagName === 'INPUT' ? '' : 'block';
          node = node.parentElement;
        }
        if (field) field.disabled = false;
      });
    JS
  end

  def assert_paper_submit_still_gated
    assert_button 'Submit Paper Application', disabled: true
    status = page.find('[data-paper-application-target="status"]', visible: :all).text
    assert_match(/Complete all required confirmations before submitting/i, status)
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
