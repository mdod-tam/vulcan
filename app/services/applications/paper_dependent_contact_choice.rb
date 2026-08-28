# frozen_string_literal: true

module Applications
  # Owns the paper-only rule that an explicit dependent-contact choice must carry its own value.
  # Both the read-only preview and the durable writer call this object so staff are never shown an
  # identity decision that the writer will reject for a different interpretation of the same form.
  class PaperDependentContactChoice
    Result = Data.define(:valid, :field, :reason, :message) do
      def valid?
        valid
      end

      def identity_review_payload
        return if valid?

        {
          state: :invalid_contact_choice,
          reasons: [reason],
          candidates: [],
          field: field,
          message: message
        }
      end
    end

    def initialize(applicant_data:, strategy_params:)
      @applicant_data = applicant_data.to_h.with_indifferent_access
      @strategy_params = strategy_params.to_h.with_indifferent_access
    end

    def call
      return missing_email if own_email_selected? && own_email.blank?
      return missing_phone if own_phone_selected? && own_phone.blank?

      Result.new(valid: true, field: nil, reason: nil, message: nil)
    end

    private

    attr_reader :applicant_data, :strategy_params

    def own_email_selected?
      strategy_params[:email_strategy].to_s == 'dependent'
    end

    def own_phone_selected?
      strategy_params[:phone_strategy].to_s == 'dependent'
    end

    def own_email
      applicant_data[:dependent_email].presence || applicant_data[:email]
    end

    def own_phone
      applicant_data[:dependent_phone].presence || applicant_data[:phone]
    end

    def missing_email
      Result.new(
        valid: false,
        field: :dependent_email,
        reason: :missing_dependent_email,
        message: "Enter the dependent's email or choose the guardian's email address."
      )
    end

    def missing_phone
      Result.new(
        valid: false,
        field: :dependent_phone,
        reason: :missing_dependent_phone,
        message: "Enter the dependent's phone or choose the guardian's phone number."
      )
    end
  end
end
