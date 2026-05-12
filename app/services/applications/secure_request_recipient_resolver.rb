# frozen_string_literal: true

module Applications
  class SecureRequestRecipientResolver
    Candidate = Struct.new(
      :recipient,
      :recipient_role,
      :recipient_relationship_type,
      :channel,
      :email,
      :phone,
      :locale,
      :failure_reason
    ) do
      def success?
        failure_reason.blank?
      end

      def email_override_available?
        channel == :letter && email.present?
      end
    end

    attr_reader :application, :recipient_ids, :channel_overrides

    def initialize(application:, recipient_ids: nil, channel_overrides: {}, known_recipients: nil, guardian_relationships: nil)
      @application = application
      @recipient_ids_provided = !recipient_ids.nil?
      @recipient_ids = Array(recipient_ids).compact_blank.map(&:to_i)
      @channel_overrides = (channel_overrides || {}).transform_keys(&:to_i).transform_values(&:to_s)
      @known_recipients = known_recipients
      @guardian_relationships = guardian_relationships
    end

    def resolve
      requested_recipients.map { |recipient| candidate_for(recipient) }
    end

    def default_recipient_ids
      default_recipients.map(&:id)
    end

    def known_recipients
      return @known_recipients unless @known_recipients.nil?

      [application.user, application.managing_guardian, *guardian_users].compact.uniq(&:id)
    end

    def guardian_relationships
      return @guardian_relationships unless @guardian_relationships.nil?

      @guardian_relationships = GuardianRelationship
                                .includes(:guardian_user)
                                .where(dependent_id: application.user_id)
                                .to_a
    end

    private

    def requested_recipients
      return default_recipients unless @recipient_ids_provided
      return [] if recipient_ids.blank?

      known_by_id = known_recipients.index_by(&:id)
      recipient_ids.filter_map { |id| known_by_id[id] }
    end

    def default_recipients
      return [application.user] if application.managing_guardian_id.blank?
      return [application.user] unless dependent_application?

      application_contact_guardian.present? ? [application_contact_guardian] : [application.user]
    end

    def guardian_users
      guardian_relationships.map(&:guardian_user)
    end

    def dependent_application?
      application.user.respond_to?(:dependent?) && application.user.dependent?
    end

    def application_contact_guardian
      return @application_contact_guardian if defined?(@application_contact_guardian)

      @application_contact_guardian =
        if dependent_application? && application.managing_guardian.present? &&
           dependent_effective_email_matches?(application.managing_guardian)
          application.managing_guardian
        end
    end

    def dependent_effective_email_matches?(guardian)
      dependent_email = application.user.effective_email if application.user.respond_to?(:effective_email)
      dependent_email = application.user.email if dependent_email.blank?

      normalized_email(dependent_email).present? &&
        normalized_email(dependent_email) == normalized_email(guardian&.email)
    end

    def normalized_email(email)
      email.to_s.strip.downcase
    end

    def candidate_for(recipient)
      relationship = relationship_for(recipient)
      role = relationship.present? ? :guardian : :constituent
      email = email_for(recipient, role)
      phone = phone_for(recipient, role)
      channel = preferred_secure_request_delivery_channel(recipient, email: email, phone: phone)

      if channel.blank?
        return Candidate.new(
          recipient: recipient,
          recipient_role: role,
          recipient_relationship_type: relationship&.relationship_type,
          email: email,
          phone: phone,
          locale: locale_for(recipient, role),
          failure_reason: :no_contact_path
        )
      end

      Candidate.new(
        recipient: recipient,
        recipient_role: role,
        recipient_relationship_type: relationship&.relationship_type,
        channel: channel,
        email: email,
        phone: phone,
        locale: locale_for(recipient, role)
      )
    end

    def relationship_for(recipient)
      return nil if recipient.id == application.user_id

      relationship_by_guardian_id[recipient.id]
    end

    def relationship_by_guardian_id
      @relationship_by_guardian_id ||= guardian_relationships.index_by(&:guardian_id)
    end

    def email_for(recipient, role)
      return recipient.email if role == :guardian
      return dependent_email_for_application if recipient.id == application.user_id && dependent_application?

      if recipient.respond_to?(:effective_email)
        recipient.effective_email.presence || recipient.email
      else
        recipient.email
      end
    end

    def phone_for(recipient, role)
      return recipient.phone if role == :guardian
      return dependent_phone_for_application if recipient.id == application.user_id && dependent_application?

      if recipient.respond_to?(:effective_phone)
        recipient.effective_phone.presence || recipient.phone
      else
        recipient.phone
      end
    end

    def locale_for(recipient, role)
      return recipient.locale if role == :guardian
      return dependent_locale_for_application if recipient.id == application.user_id && dependent_application?

      if recipient.respond_to?(:effective_locale)
        recipient.effective_locale.presence || recipient.locale
      else
        recipient.locale
      end
    end

    def dependent_email_for_application
      return application_contact_guardian.email if application_contact_guardian.present?

      dependent_email = application.user.dependent_email.presence
      return dependent_email if dependent_email.present? && !guardian_email?(dependent_email)
      return application.user.email unless system_generated_email?(application.user.email)

      nil
    end

    def dependent_phone_for_application
      return application_contact_guardian.phone if application_contact_guardian.present?

      dependent_phone = application.user.dependent_phone.presence
      return dependent_phone if dependent_phone.present? && !guardian_phone?(dependent_phone)
      return application.user.phone unless placeholder_phone?(application.user.phone)

      nil
    end

    def dependent_locale_for_application
      application_contact_guardian&.locale || application.user.locale
    end

    def guardian_email?(email)
      normalized = normalized_email(email)
      return false if normalized.blank?

      guardian_users.any? { |guardian| normalized_email(guardian.email) == normalized }
    end

    def guardian_phone?(phone)
      normalized = normalized_phone(phone)
      return false if normalized.blank?

      guardian_users.any? { |guardian| normalized_phone(guardian.phone) == normalized }
    end

    def normalized_phone(phone)
      phone.to_s.gsub(/\D/, '')
    end

    def system_generated_email?(email)
      normalized_email(email).end_with?('@system.matvulcan.local')
    end

    def placeholder_phone?(phone)
      normalized_phone(phone).start_with?('000000')
    end

    def preferred_secure_request_delivery_channel(recipient, email:, phone:)
      return :email if letter_to_email_override_allowed?(recipient, email)

      phone_type = phone_type_for(recipient)
      preferred_channel = channel_for_phone_type(phone_type, email: email, phone: phone)
      return preferred_channel if preferred_channel.present?
      return :letter if recipient_letter_preferred?(recipient) && mailing_address_present?(recipient)
      return :email if email.present?

      nil
    end

    def letter_to_email_override_allowed?(recipient, email)
      channel_overrides[recipient.id] == 'email' && email.present? && recipient_letter_preferred?(recipient)
    end

    def channel_for_phone_type(phone_type, email:, phone:)
      return :sms if phone_type == 'text' && phone.present?
      return :email if phone_type == 'email' && email.present?

      nil
    end

    def recipient_letter_preferred?(recipient)
      preference =
        if recipient.id == application.user_id && dependent_application?
          application_contact_guardian&.communication_preference || recipient.communication_preference
        elsif recipient.respond_to?(:effective_communication_preference)
          recipient.effective_communication_preference
        elsif recipient.respond_to?(:communication_preference)
          recipient.communication_preference
        end

      preference.to_s == 'letter'
    end

    def phone_type_for(recipient)
      if recipient.id == application.user_id && dependent_application?
        application_contact_guardian&.phone_type || recipient.phone_type
      elsif recipient.respond_to?(:effective_phone_type)
        recipient.effective_phone_type
      elsif recipient.respond_to?(:phone_type)
        recipient.phone_type
      end.to_s
    end

    def mailing_address_present?(recipient)
      %i[physical_address_1 city state zip_code].all? { |attr| recipient.public_send(attr).present? }
    end
  end
end
