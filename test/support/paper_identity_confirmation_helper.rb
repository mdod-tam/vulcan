# frozen_string_literal: true

# Supply a keep-separate decision for new self-applicant test setup.
# Ask the review owner for a receipt. Do not run the application writer as a probe.
# If the review supplies no receipt, return the original params.
module PaperIdentityConfirmationHelper
  # @param service_params [Hash] The params for the paper application service.
  # @param admin [User] The admin whose identity binds the receipt.
  # @return [Hash] The params, with a decision when the review supplies a receipt.
  def confirmed_paper_params(service_params, admin:)
    return service_params unless new_self_applicant_scenario?(service_params)

    review = Applications::PaperIdentityReview.new(
      constituent_params: service_params[:constituent],
      admin: admin,
      contact_flag_params: service_params
    ).call
    # The writer rechecks any supplied receipt and can still refuse hard blocks or changed facts.
    return service_params if review.token.blank?

    service_params.merge(identity_review_receipt: review.token, identity_determination: 'keep_separate',
                         identity_rationale: 'Staff compared the paper applicant with each possible match.')
  end

  private

  # Leave existing applicants and guardian/dependent requests to their own identity paths.
  def new_self_applicant_scenario?(params)
    return false if params[:existing_constituent_id].present?
    return false if params[:dependent_id].present? || params[:guardian_id].present?
    return false if params[:applicant_type].to_s == 'dependent'

    params[:constituent].present?
  end
end
