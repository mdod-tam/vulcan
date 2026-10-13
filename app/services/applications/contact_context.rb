# frozen_string_literal: true

module Applications
  # Display and delivery contacts for one application; never login identity.
  # UserGuardianship owns contact strategy, while the application selects the guardian.
  class ContactContext
    attr_reader :application, :applicant, :guardian, :email_contact, :phone_contact, :address_owner

    def initialize(application:, related_guardians: nil)
      @application = application
      @applicant = application.user
      @related_guardians = related_guardians
      @guardian = application.managing_guardian if applicant.dependent?
      @email_contact = resolve_contact(:email)
      @phone_contact = resolve_contact(:phone)
      @address_owner = if applicant.dependent?
                         applicant.dependent_mailing_address_owner(contact_guardian: guardian)
                       else
                         applicant
                       end
    end

    def email
      email_contact&.value
    end

    def email_owner
      email_contact&.owner
    end

    def phone
      phone_contact&.value
    end

    def phone_owner
      phone_contact&.owner
    end

    def preference_owner
      guardian || applicant
    end

    def communication_owner
      preference_owner
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
             :alternate_contact_relationship_type, to: :application

    private

    def resolve_contact(field)
      if applicant.dependent?
        applicant.public_send("dependent_#{field}_contact", contact_guardian: guardian,
                                                            related_guardians: @related_guardians)
      elsif applicant.public_send("real_#{field}?")
        UserGuardianship::OwnedContact.new(value: applicant.public_send(field), owner: applicant, source: :constituent)
      end
    end
  end
end
