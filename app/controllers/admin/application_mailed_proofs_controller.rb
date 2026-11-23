# frozen_string_literal: true

module Admin
  class ApplicationMailedProofsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      proof_type = params[:proof_type].to_s
      return redirect_to admin_application_path(@application), status: :see_other, alert: 'No mailed request exists for this proof.' unless mailed_request?(proof_type)

      result = ProofAttachmentService.attach_proof(
        application: @application, proof_type: proof_type,
        blob_or_file: UploadedDocument.submitted(params, DocumentType.fetch(proof_type).attachment_name),
        submission_method: :paper, admin: current_user, require_requestable: true
      )
      redirect_to admin_application_path(@application), status: :see_other, **attachment_feedback(result)
    rescue UploadedDocument::Refused => e
      redirect_to admin_application_path(@application), status: :see_other, alert: e.user_message
    end

    private

    def mailed_request?(proof_type)
      ProofReview.reviewable_proof_type?(proof_type) &&
        @application.secure_request_forms.recipient_channel_letter.exists?(kind: "#{proof_type}_proof_resubmission")
    end

    def attachment_feedback(result)
      return { notice: 'Mailed proof uploaded for review.' } if result[:success]
      return { alert: 'This proof is no longer needed.' } if result[:error].is_a?(ProofAttachmentService::ProofNoLongerNeeded)

      { alert: 'The upload could not be confirmed. Check the application before trying again.' }
    end
  end
end
