# frozen_string_literal: true

module ProofResubmissionTestHelper
  # Suppresses ProofReview after_commit resubmission delivery for the duration of the block.
  # Use when tests need a rejected review as setup state without issuing a real secure request.
  def without_auto_resubmission
    noop = mock('suppressed-resubmission')
    noop.stubs(:call).returns(BaseService::Result.new(success: true, message: 'suppressed', data: {}))
    Applications::RequestProofResubmission.stubs(:new).returns(noop)
    yield
  ensure
    Applications::RequestProofResubmission.unstub(:new)
  end

  def create_rejected_proof_review_without_auto_resubmission(**attributes)
    without_auto_resubmission do
      create(:proof_review, status: :rejected, **attributes)
    end
  end
end
