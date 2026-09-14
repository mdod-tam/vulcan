# frozen_string_literal: true

module Applications
  # Canonical secure-request router: logical recipient, contact owner, source, and channel.
  # UserGuardianship owns persisted dependent contact ownership, and
  # UserContactPredicates owns contact validity. Fallback contact affects delivery only.
  # The resolver never copies contact onto a constituent or grants portal access.
  #
  # Explicit overrides require a real email, a real text-capable phone, or a complete address.
  # An SMS override with a voice, videophone, synthetic, malformed, or stale phone fails with :invalid_channel_override.
  # SMS requires an override. Invalid overrides never fall back to another channel.
  # Letters require a complete address and permission from the action.
  # Default selection honors letter preference, then tries email, then letter, within eligible routes.
  # No permissible route returns :no_contact_path before any token, form, notification, or audit event.
  #
  # available_channels describes contact validity independently of delivery-owner eligibility.
  # channel_eligibility, deliverable_channels, and owner_ineligible_channels expose owner restrictions.
  # Default selection can use another eligible route when an owner is suspended, inactive, or merged.
  class SecureRequestRecipientResolver
    PERMITTED_CHANNELS = %i[email letter sms].freeze

    FAILURE_REASONS = %i[no_contact_path invalid_channel_override].freeze

    Candidate = Struct.new(
      :recipient,
      :recipient_role,
      :recipient_relationship_type,
      :email_owner,
      :phone_owner,
      :delivery_source,
      :available_channels,
      :channel,
      :email,
      :phone,
      :phone_type,
      :address_owner,
      :failure_reason
    ) do
      def success?
        failure_reason.blank?
      end

      def delivery_owner
        delivery_owner_for(channel)
      end

      # Separate field owners preserve provenance for each channel.
      def delivery_owner_for(channel)
        case channel&.to_sym
        when :letter then address_owner
        when :email then email_owner
        when :sms then phone_owner
        end
      end

      # available_channels retains routes whose owners are ineligible.
      # Self-owned channels stay :ok here. The caller's locked delivery_participants_eligible?
      # check reports recipient ineligibility separately from an unavailable route.
      def channel_eligibility
        @channel_eligibility ||= available_channels.to_h do |available_channel|
          owner = delivery_owner_for(available_channel)
          eligible = owner.nil? || owner.id == recipient.id || owner.secure_request_delivery_eligible?
          [available_channel, eligible ? :ok : :owner_ineligible]
        end
      end

      def deliverable_channels
        available_channels.select { |available_channel| channel_eligibility[available_channel] == :ok }
      end

      def owner_ineligible_channels
        available_channels - deliverable_channels
      end

      # Delivery eligibility includes guardians who supply a dependent's contact or address.
      def delivery_participants_eligible?
        participants = [recipient, delivery_owner].compact.uniq(&:id)
        participants.all?(&:secure_request_delivery_eligible?)
      end
    end

    attr_reader :application, :recipient_ids, :channel_overrides, :permitted_channels

    def initialize(application:, recipient_ids: nil, channel_overrides: {}, permitted_channels: PERMITTED_CHANNELS,
                   known_recipients: nil, guardian_relationships: nil)
      @application = application
      @recipient_ids_provided = !recipient_ids.nil?
      @recipient_ids = Array(recipient_ids).compact_blank.map(&:to_i)
      @channel_overrides = (channel_overrides || {}).transform_keys(&:to_i).transform_values(&:to_s)
      @permitted_channels = (Array(permitted_channels).map(&:to_sym) & PERMITTED_CHANNELS).freeze
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

    def dependent_recipient?(recipient)
      recipient.id == application.user_id && dependent_application?
    end

    def application_contact_guardian
      return @application_contact_guardian if defined?(@application_contact_guardian)

      contact = application_user_email_contact
      @application_contact_guardian = contact.owner if contact&.source == :guardian
    end

    def candidate_for(recipient)
      relationship = relationship_for(recipient)
      role = if relationship.present? || recipient.id == application.managing_guardian_id
               :guardian
             else
               :constituent
             end
      email, email_owner, email_source = email_selection_for(recipient, role)
      phone, phone_owner, phone_source = phone_selection_for(recipient, role)
      phone_type = phone_owner&.phone_type
      address_owner = address_owner_for(recipient, role)
      available = available_channels_for(
        email: email,
        phone: phone,
        phone_type: phone_type,
        address_owner: address_owner
      )
      channel, failure_reason = select_channel(recipient, available_channels: available,
                                                          address_owner: address_owner,
                                                          email_owner: email_owner, phone_owner: phone_owner)

      Candidate.new(
        recipient: recipient,
        recipient_role: role,
        recipient_relationship_type: relationship&.relationship_type,
        email_owner: email_owner,
        phone_owner: phone_owner,
        delivery_source: delivery_source_for(recipient, role, address_owner, channel, email_source, phone_source),
        available_channels: available,
        channel: channel,
        email: email,
        phone: phone,
        phone_type: phone_type,
        address_owner: address_owner,
        failure_reason: failure_reason
      )
    end

    # Selections adapt model-owned contact truth to secure-form provenance.
    def email_selection_for(recipient, role)
      return own_contact_selection(recipient, :email, guardian_source_for(recipient)) if role == :guardian

      return resolver_selection(application_user_email_contact) if dependent_recipient?(recipient)

      own_contact_selection(recipient, :email, :constituent)
    end

    def phone_selection_for(recipient, role)
      return own_contact_selection(recipient, :phone, guardian_source_for(recipient)) if role == :guardian

      return resolver_selection(application_user_phone_contact) if dependent_recipient?(recipient)

      own_contact_selection(recipient, :phone, :constituent)
    end

    def application_user_email_contact
      @application_user_email_contact ||= application.user.dependent_email_contact(
        contact_guardian: application.managing_guardian,
        related_guardians: guardian_users
      )
    end

    def application_user_phone_contact
      @application_user_phone_contact ||= application.user.dependent_phone_contact(
        contact_guardian: application.managing_guardian,
        related_guardians: guardian_users
      )
    end

    def resolver_selection(contact)
      return [nil, nil, nil] unless contact

      source = contact.source == :guardian ? :managing_guardian : contact.source
      [contact.value, contact.owner, source]
    end

    def own_contact_selection(owner, kind, source)
      return [nil, nil, nil] unless owner.public_send("real_#{kind}?")

      [owner.public_send(kind), owner, source]
    end

    # Legacy rows do not persist address strategy; use the dependent only when the
    # managing guardian has no usable mailing address.
    def address_owner_for(recipient, role)
      return recipient if role == :guardian
      return recipient unless dependent_recipient?(recipient)

      recipient.dependent_mailing_address_owner(contact_guardian: application.managing_guardian)
    end

    def available_channels_for(email:, phone:, phone_type:, address_owner:)
      channels = []
      channels << :email if permits?(:email) && email.present?
      channels << :letter if permits?(:letter) && address_owner&.complete_mailing_address?
      channels << :sms if permits?(:sms) && sms_capable_contact?(phone, phone_type)
      channels
    end

    def permits?(channel)
      permitted_channels.include?(channel)
    end

    # phone_type belongs to the selected phone's owner, which can differ from the recipient.
    def sms_capable_contact?(phone, phone_type)
      return false if phone.blank?
      return false unless phone_type.to_s == 'text'

      User.new(phone: phone).real_phone?
    end

    # Overrides use available_channels. The caller's locked delivery_participants_eligible?
    # check enforces owner eligibility. Only default selection can try another eligible route.
    def select_channel(recipient, available_channels:, address_owner:, email_owner:, phone_owner:)
      override = channel_overrides[recipient.id].to_s.strip
      if override.present?
        requested = override.downcase.to_sym
        return [requested, nil] if available_channels.include?(requested)

        return [nil, :invalid_channel_override]
      end

      deliverable = deliverable_channels_for(available_channels, recipient: recipient,
                                                                 address_owner: address_owner,
                                                                 email_owner: email_owner, phone_owner: phone_owner)
      return [:letter, nil] if recipient_letter_preferred?(recipient) && deliverable.include?(:letter)
      return [:email, nil] if deliverable.include?(:email)
      return [:letter, nil] if deliverable.include?(:letter)

      [nil, :no_contact_path]
    end

    # Self-owned channels remain available so the caller's locked check can
    # report recipient ineligibility instead of a missing route.
    def deliverable_channels_for(available_channels, recipient:, address_owner:, email_owner:, phone_owner:)
      available_channels.select do |available_channel|
        owner = case available_channel
                when :letter then address_owner
                when :email then email_owner
                when :sms then phone_owner
                end
        owner.nil? || owner.id == recipient.id || owner.secure_request_delivery_eligible?
      end
    end

    # Provenance follows the selected channel. A dependent-owned email must not
    # label an SMS to the constituent's own phone as dependent contact.
    def delivery_source_for(recipient, role, address_owner, channel, email_source, phone_source)
      case channel&.to_sym
      when :letter
        return guardian_source_for(recipient) if role == :guardian
        return :constituent if address_owner.nil? || address_owner.id == recipient.id
        return :managing_guardian if address_owner.id == application.managing_guardian_id

        :guardian_relationship
      when :sms
        phone_source
      when :email
        email_source
      end
    end

    def relationship_for(recipient)
      return nil if recipient.id == application.user_id

      relationship_by_guardian_id[recipient.id]
    end

    def relationship_by_guardian_id
      @relationship_by_guardian_id ||= guardian_relationships.index_by(&:guardian_id)
    end

    def guardian_source_for(recipient)
      relationship_for(recipient).present? ? :guardian_relationship : :managing_guardian
    end

    def recipient_letter_preferred?(recipient)
      preference =
        if dependent_recipient?(recipient)
          application_contact_guardian&.communication_preference || recipient.communication_preference
        elsif recipient.respond_to?(:effective_communication_preference)
          recipient.effective_communication_preference
        elsif recipient.respond_to?(:communication_preference)
          recipient.communication_preference
        end

      preference.to_s == 'letter'
    end
  end
end
