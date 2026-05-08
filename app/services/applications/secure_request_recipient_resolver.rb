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
      if application.managing_guardian_id.present?
        [application.managing_guardian]
      else
        [application.user]
      end
    end

    def guardian_users
      guardian_relationships.map(&:guardian_user)
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

      if recipient.respond_to?(:effective_email)
        recipient.effective_email.presence || recipient.email
      else
        recipient.email
      end
    end

    def phone_for(recipient, role)
      return recipient.phone if role == :guardian

      if recipient.respond_to?(:effective_phone)
        recipient.effective_phone.presence || recipient.phone
      else
        recipient.phone
      end
    end

    def locale_for(recipient, role)
      return recipient.locale if role == :guardian

      if recipient.respond_to?(:effective_locale)
        recipient.effective_locale.presence || recipient.locale
      else
        recipient.locale
      end
    end

    def preferred_secure_request_delivery_channel(recipient, email:, phone:)
      return :email if letter_to_email_override_allowed?(recipient, email)

      phone_type = recipient.phone_type.to_s
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
      preference = recipient.communication_preference if recipient.respond_to?(:communication_preference)

      preference.to_s == 'letter'
    end

    def mailing_address_present?(recipient)
      %i[physical_address_1 city state zip_code].all? { |attr| recipient.public_send(attr).present? }
    end
  end
end
