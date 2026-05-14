# frozen_string_literal: true

require 'test_helper'

class ApplicationProofAttachmentValidationTest < ActiveSupport::TestCase
  setup do
    @previous_require_proof_validations = ENV.fetch('REQUIRE_PROOF_VALIDATIONS', nil)
    ENV['REQUIRE_PROOF_VALIDATIONS'] = 'true'
    Current.reset
  end

  teardown do
    if @previous_require_proof_validations.nil?
      ENV.delete('REQUIRE_PROOF_VALIDATIONS')
    else
      ENV['REQUIRE_PROOF_VALIDATIONS'] = @previous_require_proof_validations
    end
    Current.reset
  end

  test 'rejected missing proofs are valid under required proof validations' do
    application = create(:application, :in_progress)
    application.update_columns(
      income_proof_status: Application.income_proof_statuses[:rejected],
      residency_proof_status: Application.residency_proof_statuses[:rejected]
    )

    assert application.reload.valid?, "Expected rejected missing proofs to be valid: #{application.errors.full_messages}"
  end

  test 'pending missing proofs still fail required proof validations' do
    application = create(:application, :in_progress)

    assert_not application.valid?
    assert_includes application.errors[:income_proof], 'must be attached. Please upload your income documentation.'
    assert_includes application.errors[:residency_proof], 'must be attached. Please upload your proof of Maryland residency.'
  end

  test 'approved missing proofs still fail required proof validations' do
    application = create(:application, :in_progress)
    application.update_columns(
      income_proof_status: Application.income_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved]
    )

    assert_not application.reload.valid?
    assert_includes application.errors[:income_proof], 'must be attached. Please upload your income documentation.'
    assert_includes application.errors[:residency_proof], 'must be attached. Please upload your proof of Maryland residency.'
  end
end
