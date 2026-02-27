# frozen_string_literal: true

module Variables
  class ProofApproved
    include Mailers::ApplicationNotificationsHelper

    def initialize(application, proof_review, base_variables:)
      @application    = application
      @proof_review   = proof_review
      @base_variables = base_variables
    end

    def to_h
      @base_variables.merge(proof_variables).compact
    end

    private

    def proof_variables
      user                 = @application.user
      organization_name    = Policy.get('organization_name') || 'MAT Program'
      proof_type_formatted = format_proof_type(@proof_review.proof_type)
      all_proofs_approved  = @application.respond_to?(:all_proofs_approved?) && @application.all_proofs_approved?

      {
        user_first_name: user.first_name,
        organization_name: organization_name,
        proof_type_formatted: proof_type_formatted,
        all_proofs_approved_message_text: all_proofs_approved ? 'All required documents for your application have now been approved.' : ''
      }
    end
  end
end
