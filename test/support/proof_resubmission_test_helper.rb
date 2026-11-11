# frozen_string_literal: true

module ProofResubmissionTestHelper
  def proof_decision_params(application, proof_type)
    { decision_key: SecureRandom.uuid, reviewed_blob_id: DocumentType::BY_KEY.key?(proof_type.to_s) ? application.document_attachment_for(proof_type).blob&.id : nil }
  end

  def record_proof_review(application:, admin:, proof_type:, status:, **attributes)
    identity = proof_decision_params(application, proof_type).merge(attributes.extract!(:decision_key, :reviewed_blob_id))
    ProofReview.record_decision!(application: application, admin: admin, proof_type: proof_type, status: status,
                                 **identity, **attributes, &:record!).review
  end

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
