# frozen_string_literal: true

module Evaluations
  # Display and delivery contacts for one application; never login identity.
  # UserGuardianship owns contact strategy, while the application selects the guardian.
  class ContactContext
    attr_reader :applicant, :guardian, :email, :email_owner, :phone, :phone_owner, :address_owner

    def initialize(evaluation)
      @application = evaluation.application
      @applicant = evaluation.constituent
      @guardian = @application.managing_guardian if applicant.dependent?
      @email, @email_owner = resolve_contact(:email)
      @phone, @phone_owner = resolve_contact(:phone)
      @address_owner = if applicant.dependent?
                         applicant.dependent_mailing_address_owner(contact_guardian: guardian)
                       else
                         applicant
                       end
    end

    def communication_owner
      email_owner || phone_owner || guardian || applicant
    end

    def phone_type
      (phone_owner || communication_owner).phone_type
    end

    delegate :communication_preference, :locale, to: :communication_owner

    def email_locale
      email_owner&.locale
    end

    def phone_locale
      phone_owner&.locale
    end

    def communication_modality
      communication_owner.preferred_means_of_communication
    end

    delegate :alternate_contact_name, :alternate_contact_phone, :alternate_contact_email,
             :alternate_contact_relationship_type, to: :@application

    private

    def resolve_contact(field)
      if applicant.dependent?
        contact = applicant.public_send("dependent_#{field}_contact", contact_guardian: guardian)
        [contact&.value, contact&.owner]
      elsif applicant.public_send("real_#{field}?")
        [applicant.public_send(field), applicant]
      else
        [nil, nil]
      end
    end
  end
end
