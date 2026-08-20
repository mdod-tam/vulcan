# frozen_string_literal: true

# Paper self-applicant creation asks staff to decide when the search surfaces a possible match:
# select that constituent, or record that this is a different person. Tests that are not *about*
# that contract take the override the way staff would.
#
# Nothing is needed when the search finds nothing -- that path creates normally -- so this is a
# no-op for most callers.
#
# This calls the read-only review owner directly rather than running the writer. An earlier version
# probed by invoking PaperApplicationService, which was unsafe: a new-dependent request carries
# neither existing_constituent_id nor dependent_id, so it fell through to the guardian/dependent
# branch and the "probe" created real records the caller then tripped over.
#
# Shared rather than duplicated per file because the requirement fans out across every test that
# creates a paper constituent, and a second copy would drift the moment the contract changes.
module PaperIdentityConfirmationHelper
  # @param service_params [Hash] the params a test would otherwise pass straight to the service
  # @param admin [User] the acting admin, which the decision is bound to
  # @return [Hash] the same params, carrying a confirmation when the self-applicant branch needs one
  def confirmed_paper_params(service_params, admin:)
    return service_params unless new_self_applicant_scenario?(service_params)

    review = Applications::PaperIdentityReview.new(
      constituent_params: service_params[:constituent],
      admin: admin,
      contact_flag_params: service_params
    ).call
    # Only a soft match needs a decision. Nothing surfacing creates normally, and a hard block or
    # detection failure is not confirmable at all -- in those cases the test should see the writer's
    # own behaviour rather than a confirmation that papers over it.
    return service_params if review.token.blank?

    service_params.merge(identity_decision: review.token)
  end

  private

  # Only the branch that creates a *new* self applicant reaches the no-match gate. Selecting an
  # existing constituent, and anything routed to the guardian/dependent path, must be left alone.
  def new_self_applicant_scenario?(params)
    return false if params[:existing_constituent_id].present?
    return false if params[:dependent_id].present? || params[:guardian_id].present?
    return false if params[:applicant_type].to_s == 'dependent'

    params[:constituent].present?
  end
end
