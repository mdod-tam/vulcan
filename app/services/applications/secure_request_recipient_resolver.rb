# frozen_string_literal: true

module Applications
  # Canonical secure-request router: logical recipient, contact owner, source, and channel.
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

    # Bounded provenance for the selected contact. Values: :constituent (the application
    # constituent's own record), :dependent_contact (a dependent-owned contact field),
    # :managing_guardian (the application's managing guardian), :guardian_relationship
    # (an explicitly selected persisted guardian's own record).
    CONTACT_SOURCES = %i[constituent dependent_contact managing_guardian guardian_relationship].freeze

    FAILURE_REASONS = %i[no_contact_path invalid_channel_override].freeze

    Candidate = Struct.new(
      :recipient,
      :recipient_role,
      :recipient_relationship_type,
      :contact_owner,
      :email_owner,
      :phone_owner,
      :contact_source,
      :delivery_source,
      :available_channels,
      :channel,
      :email,
      :phone,
      :phone_type,
      :address_owner,
      :locale,
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
        else contact_owner
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
      contact_owner = email_owner || phone_owner
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
        contact_owner: contact_owner,
        email_owner: email_owner,
        phone_owner: phone_owner,
        contact_source: email_source || phone_source,
        delivery_source: delivery_source_for(recipient, role, address_owner, channel, email_source, phone_source),
        available_channels: available,
        channel: channel,
        email: email,
        phone: phone,
        phone_type: phone_type,
        address_owner: address_owner,
        locale: locale_for(recipient, contact_owner),
        failure_reason: failure_reason
      )
    end

    # Selections return [value, owning-record, symbolic-source]. Sources come from CONTACT_SOURCES.
    # Shared predicates exclude synthetic contact values.
    def email_selection_for(recipient, role)
      return own_contact_selection(recipient, recipient.email, :email, guardian_source_for(recipient)) if role == :guardian

      if dependent_recipient?(recipient)
        if application_contact_guardian.present?
          return own_contact_selection(application_contact_guardian, application_contact_guardian.email, :email,
                                       :managing_guardian)
        end

        dependent_email = recipient.dependent_email.to_s.strip.presence
        return own_contact_selection(recipient, dependent_email, :email, :dependent_contact) if dependent_email.present? && !guardian_email?(dependent_email)
      end

      own_contact_selection(recipient, recipient.email, :email, :constituent)
    end

    def phone_selection_for(recipient, role)
      return own_contact_selection(recipient, recipient.phone, :phone, guardian_source_for(recipient)) if role == :guardian

      if dependent_recipient?(recipient)
        guardian = application.managing_guardian
        dependent_phone = recipient.paper_intake_own_phone(guardian:)
        if dependent_phone.blank? && guardian.present?
          return own_contact_selection(guardian, guardian.phone, :phone,
                                       :managing_guardian)
        end

        if dependent_phone.present? && !guardian_phone?(dependent_phone)
          source = normalized_phone(dependent_phone) == normalized_phone(recipient.dependent_phone) ? :dependent_contact : :constituent
          return own_contact_selection(recipient, dependent_phone, :phone, source)
        end
      end

      own_contact_selection(recipient, recipient.phone, :phone, :constituent)
    end

    def own_contact_selection(owner, value, kind, source)
      value = value.to_s.strip.presence
      return [nil, nil, nil] if value.blank?

      accepted = kind == :email ? real_email_value(value) : real_phone_value(value)
      accepted.present? ? [accepted, owner, source] : [nil, nil, nil]
    end

    # Detached User probes reuse contact predicates, as in UserProfile:
    # User.new(phone: ...).real_phone?
    def real_email_value(value)
      value if User.new(email: value).real_email?
    end

    def real_phone_value(value)
      value if User.new(phone: value).real_phone?
    end

    # Legacy rows do not persist address strategy; use the dependent only when the
    # managing guardian has no usable mailing address.
    def address_owner_for(recipient, role)
      return recipient if role == :guardian
      return recipient unless dependent_recipient?(recipient)

      guardian = application.managing_guardian
      return recipient if complete_mailing_address?(recipient) && !complete_mailing_address?(guardian)

      guardian || recipient
    end

    def available_channels_for(email:, phone:, phone_type:, address_owner:)
      channels = []
      channels << :email if permits?(:email) && email.present?
      channels << :letter if permits?(:letter) && complete_mailing_address?(address_owner)
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

    def complete_mailing_address?(owner)
      return false if owner.blank?

      %i[physical_address_1 city state zip_code].all? { |attr| owner.public_send(attr).present? }
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
      else
        email_source || phone_source
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

    def locale_for(recipient, contact_owner)
      contact_owner&.locale.presence ||
        (recipient.respond_to?(:effective_locale) ? recipient.effective_locale.presence : nil) ||
        recipient.locale
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

    # User normalizers prevent guardian contact from appearing dependent-owned.
    # dependent_email / dependent_phone are raw (e.g. "+1 410-555-1212").
    # Guardian phone columns are normalized ("410-555-1212").
    def normalized_email(email)
      User.normalize_email(email).to_s
    end

    def normalized_phone(phone)
      User.normalize_phone(phone).to_s
    end
  end
end
