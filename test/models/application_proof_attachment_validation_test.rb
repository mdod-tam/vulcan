# frozen_string_literal: true

require 'test_helper'

# The proof rules are transitions on the application, not invariants on every save: the required proofs are due when
# the application leaves draft, and a proof needs its file in the save that approves it. No ambient flag changes
# whether either runs.
class ApplicationProofAttachmentValidationTest < ActiveSupport::TestCase
  INCOME_MESSAGE = 'must be attached. Please upload your income documentation.'
  RESIDENCY_MESSAGE = 'must be attached. Please upload your proof of Maryland residency.'
  APPROVED_MESSAGE = 'must be attached when status is approved'

  test 'leaving draft without the required proofs is invalid' do
    application = create(:application, :draft)
    application.status = :in_progress

    assert_not application.valid?
    assert_includes application.errors[:income_proof], INCOME_MESSAGE
    assert_includes application.errors[:residency_proof], RESIDENCY_MESSAGE
  end

  test 'leaving draft with rejected proofs and no files is valid' do
    application = create(:application, :draft, income_proof_status: :rejected, residency_proof_status: :rejected)
    application.status = :in_progress
    application.valid?

    assert_empty application.errors[:income_proof]
    assert_empty application.errors[:residency_proof]
  end

  test 'leaving draft with the required proofs attached is valid' do
    application = create(:application, :draft)
    attach(application.income_proof, 'income.pdf')
    attach(application.residency_proof, 'residency.pdf')
    application.status = :in_progress
    application.valid?

    assert_empty application.errors[:income_proof]
    assert_empty application.errors[:residency_proof]
  end

  test 'leaving draft on a paper submission does not require files' do
    application = create(:application, :draft, submission_method: :paper)
    application.status = :in_progress
    application.valid?

    assert_empty application.errors[:income_proof]
    assert_empty application.errors[:residency_proof]
  end

  test 'saving an application that is still a draft does not require files' do
    application = create(:application, :draft)
    application.valid?

    assert_empty application.errors[:income_proof]
    assert_empty application.errors[:residency_proof]
  end

  test 'saving a submitted application does not check the required proofs again' do
    application = create(:application, :in_progress)
    application.valid?

    assert_empty application.errors[:income_proof]
    assert_empty application.errors[:residency_proof]
  end

  test 'approving a proof without its file is invalid' do
    application = create(:application, :in_progress)
    application.income_proof_status = :approved
    application.residency_proof_status = :approved
    application.id_proof_status = :approved

    assert_not application.valid?
    assert_includes application.errors[:income_proof], APPROVED_MESSAGE
    assert_includes application.errors[:residency_proof], APPROVED_MESSAGE
    assert_includes application.errors[:id_proof], APPROVED_MESSAGE
  end

  test 'approving a proof with its file is valid' do
    application = create(:application, :in_progress)
    attach(application.residency_proof, 'residency.pdf')
    application.residency_proof_status = :approved
    application.valid?

    assert_empty application.errors[:residency_proof]
  end

  test 'a proof that is already approved is not checked again on a later save' do
    application = create(:application, :in_progress)
    application.update_columns(income_proof_status: Application.income_proof_statuses[:approved])
    application.reload
    application.valid?

    assert_empty application.errors[:income_proof]
  end

  test 'approving a proof without its file is allowed on a paper submission' do
    application = create(:application, :in_progress, submission_method: :paper)
    application.residency_proof_status = :approved
    application.valid?

    assert_empty application.errors[:residency_proof]
  end

  private

  def attach(attachment, filename)
    attachment.attach(io: StringIO.new("#{filename} content"), filename: filename, content_type: 'application/pdf')
  end
end
