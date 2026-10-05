# frozen_string_literal: true

# Validates admin review parameters, runs Applications::ProofReviewer, and returns a BaseService::Result.
# Rolled-back reviews fail; committed follow-up failures carry a warning.
class ProofReviewService < BaseService
  attr_reader :application, :admin_user, :params, :proof_type, :status, :proof_review

  # @param params [ActionController::Parameters] proof_type, status, rejection_reason, rejection_reason_code, notes
  def initialize(application, admin_user, params)
    super()
    @application = application
    @admin_user = admin_user
    @params = params
    @proof_type = params[:proof_type]&.to_s
    @status = params[:status]&.to_s
  end

  # @return [BaseService::Result] on success, data has :proof_review.
  #   A rejection also adds :resubmission_delivered and :resubmission_suppressed.
  def call
    validation_result = validate_params
    return validation_result unless validation_result.success?

    execute_review
  end

  private

  def validate_params
    return failure('Proof type and status are required') if proof_type.blank? || status.blank?

    return failure('Invalid proof type') unless ProofReview.reviewable_proof_type?(proof_type)

    return failure('Income proof review is not applicable for this application') if proof_type == 'income' && !application.income_proof_required?

    return failure('Proof is not reviewable for this application') unless application.proof_type_reviewable?(proof_type)

    return failure('Invalid status') unless %w[approved rejected].include?(status)

    success('Parameters validated successfully')
  end

  def execute_review
    log_review_start

    begin
      perform_review
      log_review_success
      success(success_message, review_result_data)
    rescue Applications::ProofReviewer::CommitUnconfirmed => e
      log_review_error(e)
      failure(e.message, { commit_state: :unknown })
    rescue StandardError => e
      log_review_error(e)
      failure("Proof review failed: #{e.message}")
    end
  end

  def perform_review
    reviewer = Applications::ProofReviewer.new(application, admin_user)
    reviewer.review(**review_params)
    @proof_review = reviewer.proof_review
    @review_warning = reviewer.warning
  end

  def review_params
    {
      proof_type: proof_type,
      status: status,
      rejection_reason: params[:rejection_reason],
      rejection_reason_code: params[:rejection_reason_code].presence,
      notes: params[:notes]
    }
  end

  def success_message
    "#{proof_type.capitalize} proof #{status} successfully."
  end

  def review_result_data
    data = { proof_review: proof_review }
    data[:warning] = @review_warning if @review_warning
    return data unless proof_review&.status_rejected?

    data.merge(
      resubmission_delivered: proof_resubmission_delivered?,
      resubmission_suppressed: proof_resubmission_suppressed?
    )
  rescue StandardError => e
    log_review_error(e)
    warning = 'The proof review was saved, but resubmission delivery could not be confirmed. Check this application before reviewing it again.'
    data.merge(warning: [data[:warning], warning].compact.join(' '))
  end

  # True when the email controls stopped the resubmission email on purpose.
  def proof_resubmission_suppressed?
    return false unless proof_review&.persisted?

    Event.where(action: 'proof_resubmission_request_failed', auditable: application)
         .where("metadata->>'proof_review_id' = ?", proof_review.id.to_s)
         .exists?(["metadata->>'delivery_suppressed' = 'true'"])
  end

  def proof_resubmission_delivered?
    return true unless proof_review&.persisted? && proof_review.created_at.present?

    Applications::RequestProofResubmission.delivery_confirmed_for_review?(proof_review)
  end

  def log_review_start
    Rails.logger.info "ProofReviewService: Starting review for Application ##{application.id}, Proof: #{proof_type}, Status: #{status}"
  end

  def log_review_success
    Rails.logger.info "ProofReviewService: Review successful for Application ##{application.id}"
  end

  def log_review_error(error)
    Rails.logger.error "ProofReviewService: Error during review for Application ##{application.id}: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")
    # Possible improvement: report the error to an error tracker such as Honeybadger.
  end
end
