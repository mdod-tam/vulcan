# frozen_string_literal: true

# Service to orchestrate the proof review process for an application.
# It handles parameter validation, calls the core ProofReviewer service,
# logs errors, and returns a structured result.
class ProofReviewService < BaseService
  attr_reader :application, :admin_user, :params, :proof_type, :status

  # Initializes the service with the application, admin user, and request parameters.
  # @param application [Application] The application being reviewed.
  # @param admin_user [User] The admin performing the review.
  # @param params [ActionController::Parameters] Request parameters including proof_type, status, etc.
  def initialize(application, admin_user, params)
    super() # Initialize parent class state
    @application = application
    @admin_user = admin_user
    @params = params
    @proof_type = params[:proof_type]&.to_s
    @status = params[:status]&.to_s
  end

  # Executes the proof review process.
  # @return [BaseService::Result] Result object with success?, message, and data
  def call
    validation_result = validate_params
    return validation_result unless validation_result.success?

    execute_review
  end

  private

  # Validates the necessary parameters for the proof review.
  # @return [BaseService::Result] Success or failure result.
  def validate_params
    return failure('Proof type and status are required') if proof_type.blank? || status.blank?

    return failure('Invalid proof type') unless %w[income residency].include?(proof_type)

    return failure('Invalid status') unless %w[approved rejected].include?(status)

    success('Parameters validated successfully') # Implicit success if no failures
  end

  # Executes the core proof review logic by calling the ProofReviewer service.
  # Handles potential errors and returns a structured result.
  # @return [BaseService::Result] Success or failure result.
  def execute_review
    log_review_start

    begin
      perform_review
      log_review_success
      success(success_message)
    rescue StandardError => e
      log_review_error(e)
      failure("Proof review failed: #{e.message}")
    end
  end

  # Performs the actual proof review by creating and calling the reviewer.
  def perform_review
    reviewer = Applications::ProofReviewer.new(application, admin_user)
    reviewer.review(**review_params)
  end

  # Returns the parameters needed for the review.
  # @return [Hash] Review parameters
  def review_params
    {
      proof_type: proof_type,
      status: status,
      rejection_reason: params[:rejection_reason],
      rejection_reason_code: params[:rejection_reason_code].presence,
      notes: params[:notes]
    }
  end

  # Returns the success message for the review.
  # @return [String] Success message
  def success_message
    "#{proof_type.capitalize} proof #{status} successfully."
  end

  # Logs the start of the review process.
  def log_review_start
    Rails.logger.info "ProofReviewService: Starting review for Application ##{application.id}, Proof: #{proof_type}, Status: #{status}"
  end

  # Logs successful completion of the review.
  def log_review_success
    Rails.logger.info "ProofReviewService: Review successful for Application ##{application.id}"
  end

  # Logs detailed information about review errors.
  # @param error [StandardError] The error that occurred.
  def log_review_error(error)
    Rails.logger.error "ProofReviewService: Error during review for Application ##{application.id}: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")
    # Consider sending to an error tracking service like Honeybadger here
  end
end
