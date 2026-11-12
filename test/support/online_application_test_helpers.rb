# frozen_string_literal: true

# Steps a constituent takes on the portal's new-application form.
module OnlineApplicationTestHelpers
  def fill_in_complete_online_application(household_size: 2, annual_income: 50_000)
    fill_in_online_application_fields(household_size:, annual_income:)
    attach_required_documents
    accept_submit_confirmations
  end

  def fill_in_online_application_fields(household_size:, annual_income:, disabilities: ['Hearing'], provider: {}, address: nil)
    check 'I certify that I am a resident of Maryland'
    fill_in 'Household Size', with: household_size
    fill_in 'Annual Income', with: annual_income
    check 'I certify that I have a disability that affects my ability to access telecommunications services'
    %w[Hearing Vision Speech Mobility Cognition].each do |label|
      disabilities.include?(label) ? check(label) : uncheck(label)
    end
    address&.each do |field, value|
      field == :state ? select(value, from: 'State') : find("input[name='application[#{field}]']").set(value)
    end

    values = { name: 'Dr. Smith', phone: '555-123-4567', email: 'dr.smith@example.com' }.merge(provider)
    within '#certifying-professional-fields' do
      values.each do |field, value|
        find("input[name='application[certifying_professional_attributes][#{field}]']").set(value)
      end
      check 'I authorize the release and sharing of my disability-related information as described above'
    end
  end

  def attach_required_documents
    attach_online_application_documents(:residency_proof, :income_proof, :id_proof)
  end

  def attach_online_application_documents(*proofs)
    fixtures = { income_proof: 'income_proof.pdf', residency_proof: 'residency_proof.pdf', id_proof: 'residency_proof.pdf' }
    proofs.each { |proof| attach_cleared_document "application_#{proof}", file_fixture(fixtures.fetch(proof)).to_s }
  end

  def save_online_application_draft
    find('input[name="save_draft"]').click
    assert_application_saved_as_draft(wait: 10)
  end

  def accept_submit_confirmations
    find_by_id('terms_accepted').check
    find_by_id('information_verified').check
  end
end
