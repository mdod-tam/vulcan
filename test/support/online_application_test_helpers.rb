# frozen_string_literal: true

# Steps a constituent takes on the portal's new-application form.
module OnlineApplicationTestHelpers
  def fill_in_complete_online_application(household_size: 2, annual_income: 50_000)
    check 'I certify that I am a resident of Maryland'
    fill_in 'Household Size', with: household_size
    fill_in 'Annual Income', with: annual_income
    check 'I certify that I have a disability that affects my ability to access telecommunications services'
    check 'Hearing'
    within '#medical-provider-fields' do
      fill_in 'Name', with: 'Dr. Smith'
      fill_in 'Phone', with: '555-123-4567'
      fill_in 'Email', with: 'dr.smith@example.com'
      check 'I authorize the release and sharing of my disability-related information as described above'
    end
    attach_required_documents
    accept_submit_confirmations
  end

  def attach_required_documents
    attach_file 'Upload Residency Proof Document', file_fixture('residency_proof.pdf').to_s
    attach_file 'Upload Income Proof Document', file_fixture('income_proof.pdf').to_s
    attach_file 'Upload ID Proof Document', file_fixture('residency_proof.pdf').to_s
  end

  def accept_submit_confirmations
    find_by_id('terms_accepted').check
    find_by_id('information_verified').check
  end
end
