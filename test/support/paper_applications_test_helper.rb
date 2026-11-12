# frozen_string_literal: true

# Form helpers for paper application system tests.
module PaperApplicationsTestHelper
  def fill_in_applicant_information(first_name: 'John', last_name: 'Doe', email: nil, phone: '555-123-4567', date_of_birth: '01/15/1980')
    email ||= "#{first_name.downcase}.#{last_name.downcase}.#{Time.now.to_i}@example.com"

    within_applicant_fieldset do
      find('input[name="constituent[first_name]"]').set(first_name)
      find('input[name="constituent[last_name]"]').set(last_name)
      find('input[name="constituent[email]"]').set(email)
      find('input[name="constituent[phone]"]').set(phone)
      find('input[name="constituent[date_of_birth]"]').set(date_of_birth)
      find('input[name="constituent[physical_address_1]"]').set('123 Main St')
      find('input[name="constituent[city]"]').set('Baltimore')
      find('input[name="constituent[state]"]').set('MD')
      find('input[name="constituent[zip_code]"]').set('21201')
    end
  end

  def fill_in_application_details(household_size: 2, annual_income: 30_000)
    within_application_details_fieldset do
      choose 'accept_income_proof', allow_label_click: true
      household_size_field = find('input[name="application[household_size]"]')
      household_size_field.set('')
      household_size_field.set(household_size.to_s)

      income_field = find('input[name="application[annual_income]"]')
      income_field.set('')
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

  def fill_in_certifying_professional_information(name: 'Dr. Smith', phone: '555-987-6543', email: 'dr.smith@example.com')
    within_certifying_professional_fieldset do
      find('input[name="application[certifying_professional_name]"]').set(name)
      find('input[name="application[certifying_professional_phone]"]').set(phone)
      find('input[name="application[certifying_professional_email]"]').set(email)
    end
  end

  def attach_and_accept_proofs
    choose 'accept_disability_certification', allow_label_click: true
    attach_cleared_document 'disability_certification', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')

    within_proof_documents_fieldset do
      choose 'accept_income_proof', allow_label_click: true
      attach_cleared_document 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')

      choose 'accept_residency_proof', allow_label_click: true
      attach_cleared_document 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

      choose 'accept_id_proof', allow_label_click: true
      attach_cleared_document 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
    end
  end

  def complete_paper_application_attestations
    check 'application[terms_accepted]' if page.has_unchecked_field?('application[terms_accepted]', wait: 1)
    check 'application[disability_information_release_authorized]' if page.has_unchecked_field?('application[disability_information_release_authorized]', wait: 1)
    check 'application[information_verified]' if page.has_unchecked_field?('application[information_verified]', wait: 1)
    sync_paper_submit_gate
  end

  def sync_paper_submit_gate
    # Blur the field so ordinary change handlers decide readiness.
    find('h1').click
  end

  # Form sections
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

  def within_certifying_professional_fieldset(&)
    within find('fieldset', text: 'Certifying Professional Information'), &
  end

  def within_proof_documents_fieldset(&)
    reveal_paper_application_common_sections
    within find('section', text: 'Proof Documents'), &
  end

  # Browser interactions
  def safe_visit(path)
    visit(path)
    wait_for_network_idle
  end

  # The path staff take for a new adult applicant: open the form and choose to create one, which
  # shows the applicant fields and the shared sections (disability, certification, proofs).
  def start_new_adult_paper_application
    visit new_admin_paper_application_path
    click_button 'Create New Applicant'
    assert_selector '#proof-heading', text: 'Proof Documents'
  end

  def select_existing_adult_through_the_ui(applicant)
    choose 'An Adult (applying for themselves)', allow_label_click: true
    fill_in 'adult_search_q', with: applicant.full_name
    within '#adult_search_results' do
      find('li', text: /#{Regexp.escape(applicant.full_name)}/i, wait: 10).click
    end
    assert_selector '[data-adult-picker-target="selectedPane"]', text: 'Applicant Selected', wait: 15
  end

  # The existing-adult submit gate requires staff verification against the paper form.
  def verify_existing_adult_contact
    box = first('[data-adult-picker-target="verificationCheckbox"]', visible: :all)
    return if box.nil? || box.checked?

    box.click
  end

  def reveal_adult_application_sections
    click_button 'Create New Applicant' unless page.has_selector?('#self-info-section', wait: 0)
    assert_selector '#self-info-section'
    reveal_paper_application_common_sections
  end

  def reveal_paper_application_common_sections
    assert_selector '#proof-heading'
  end

  def paper_fill_in(field_label, value)
    field = find_field(field_label)
    field.set('').set(value)
  rescue Capybara::ElementNotFound
    # Named-field fallback
    case field_label
    when 'Household Size'
      find('input[name="application[household_size]"]').set('').set(value)
    when 'Annual Income'
      find('input[name="application[annual_income]"]').set('').set(value)
    else
      # First-match fallback
      field = find_field(field_label, match: :first)
      field.set('').set(value)
    end
  end
end
