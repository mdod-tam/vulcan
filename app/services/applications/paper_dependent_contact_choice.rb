# frozen_string_literal: true

module Applications
  # Owns the paper-only rule that an explicit dependent-contact choice must carry its own value.
  # The read-only preview plus both new- and existing-dependent writers call this object so staff
  # are never shown an identity decision that a writer rejects under a different interpretation.
  class PaperDependentContactChoice
    Result = Data.define(:valid, :field, :reason, :message, :resolved_applicant_data) do
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

    def initialize(applicant_data:, strategy_params:, existing_dependent: nil, guardian: nil)
      @applicant_data = applicant_data.to_h.with_indifferent_access
      @strategy_params = strategy_params.to_h.with_indifferent_access
      @existing_dependent = existing_dependent
      @guardian = guardian
    end

    def call
      return missing_email if own_email_selected? && own_contact_missing?(:email)
      return missing_phone if own_phone_selected? && own_contact_missing?(:phone)

      Result.new(
        valid: true,
        field: nil,
        reason: nil,
        message: nil,
        resolved_applicant_data: resolved_applicant_data
      )
    end

    private

    attr_reader :applicant_data, :strategy_params, :existing_dependent, :guardian

    def own_email_selected?
      strategy_params[:email_strategy].to_s == 'dependent'
    end

    def own_phone_selected?
      strategy_params[:phone_strategy].to_s == 'dependent'
    end

    def own_contact_missing?(kind)
      return submitted_own_contact(kind).blank? if own_contact_submitted?(kind)

      existing_own_contact(kind).blank?
    end

    def own_contact_submitted?(kind)
      applicant_data.key?(dependent_contact_key(kind)) || applicant_data.key?(kind)
    end

    def submitted_own_contact(kind)
      applicant_data[dependent_contact_key(kind)].presence || applicant_data[kind]
    end

    def existing_own_contact(kind)
      return unless existing_dependent

      existing_dependent.public_send("paper_intake_own_#{kind}", guardian: guardian)
    end

    # An omitted field on an existing-dependent submission means "keep the on-file answer". A
    # submitted blank remains a deliberate contradiction and is refused above rather than silently
    # backfilled. New-dependent submissions have no on-file answer, so omission is invalid too.
    def resolved_applicant_data
      applicant_data.deep_dup.tap do |data|
        %i[email phone].each do |kind|
          next unless strategy_params[:"#{kind}_strategy"].to_s == 'dependent'
          next if own_contact_submitted?(kind)

          value = existing_own_contact(kind)
          data[dependent_contact_key(kind)] = value if value.present?
        end
      end
    end

    def dependent_contact_key(kind)
      :"dependent_#{kind}"
    end

    def missing_email
      Result.new(
        valid: false,
        field: :dependent_email,
        reason: :missing_dependent_email,
        message: "Enter the dependent's email or choose the guardian's email address.",
        resolved_applicant_data: applicant_data.deep_dup
      )
    end

    def missing_phone
      Result.new(
        valid: false,
        field: :dependent_phone,
        reason: :missing_dependent_phone,
        message: "Enter the dependent's phone or choose the guardian's phone number.",
        resolved_applicant_data: applicant_data.deep_dup
      )
    end
  end
end
