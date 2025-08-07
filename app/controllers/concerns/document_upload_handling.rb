# frozen_string_literal: true

module DocumentUploadHandling
  extend ActiveSupport::Concern
  include RequestMetadataHelper

  # Upload documents for proof of income or residency
  def upload_documents
    @application = find_application_for_upload

    return handle_missing_documents if params[:documents].blank?

    success = process_document_uploads
    handle_document_upload_result(success)
  end

  private

  def find_application_for_upload
    if respond_to?(:current_user) && current_user
      current_user.applications.find(params[:id])
    else
      Application.find(params[:id])
    end
  end

  def handle_missing_documents
    redirect_to application_path_for_redirect,
                alert: 'Please select documents to upload.'
  end

  def process_document_uploads
    ActiveRecord::Base.transaction do
      processed_proofs = []

      params[:documents].each do |document_type, file|
        result = attach_document(document_type, file)
        return false unless result.success?

        processed_proofs << result.type if result.type.present?
      end

      finalize_document_uploads(processed_proofs)
      true
    rescue StandardError => e
      log_error('Failed to process document uploads', e)
      false
    end
  end

  def attach_document(document_type, file)
    case document_type
    when 'income_proof'
      attach_proof_document(:income, file)
    when 'residency_proof'
      attach_proof_document(:residency, file)
    else
      # Using ApplicationDataStructures::ProofResult to process
      ApplicationDataStructures::ProofResult.new(success: false, type: nil, message: "Unknown document type: #{document_type}")
    end
  end

  def attach_proof_document(proof_type, file)
    result = ProofAttachmentService.attach_proof({
                                                   application: @application,
                                                   proof_type: proof_type,
                                                   blob_or_file: file,
                                                   status: :not_reviewed,
                                                   admin: respond_to?(:current_user) && current_user&.admin? ? current_user : nil,
                                                   submission_method: :web,
                                                   # Using RequestMetadataHelper for consistent metadata creation
                                                   metadata: basic_request_metadata
                                                 })

    # Using ApplicationDataStructures::ProofResult for consistent result handling
    ApplicationDataStructures::ProofResult.new(
      success: result[:success],
      type: proof_type.to_s,
      message: result[:message]
    )
  end

  def finalize_document_uploads(processed_proofs)
    @application.reload.save!
    flash.now[:processed_proofs] = processed_proofs
  end

  def handle_document_upload_result(success)
    if success
      redirect_to application_path_for_redirect,
                  notice: 'Documents uploaded successfully.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  def application_path_for_redirect
    if respond_to?(:constituent_portal_application_path)
      constituent_portal_application_path(@application)
    else
      admin_application_path(@application)
    end
  end
end
