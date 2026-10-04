# frozen_string_literal: true

module ConstituentPortal
  # The fingerprint pairs with `portal_creation_key` to distinguish a replay from changed input.
  # A spent key with changed persisted input must be refused, not reported as "already added".
  # Failed submissions leave the key unused, so corrected input can reuse it.
  #
  # The fingerprint normalizes only fields that the writer normalizes. Names and relationship type stay verbatim:
  # "Jane" and " jane " produce different records. Dates, email, phone, and booleans use their stored forms.
  #
  # Submitted `use_guardian_*` choices define contact inclusion, independently of the guardian's current contact.
  # A guardian contact edit must not change the fingerprint of an identical replay.
  #
  # The fingerprint excludes CSRF tokens, submit labels, the lookup key, synthetic contact, and guardian contact snapshots.
  # Explicit guardian choices ignore submitted contact fields, including stale values in hidden inputs.
  class DependentRequestFingerprint
    # A version change invalidates stored fingerprints, so different canonical forms cannot silently match.
    VERSION = 'v1'

    HMAC_PURPOSE = 'constituent_portal/dependent_request_fingerprint'

    DISABILITY_FIELDS = %i[hearing_disability vision_disability speech_disability
                           mobility_disability cognition_disability].freeze

    # @param dependent_params [ActionController::Parameters, Hash] the submitted `dependent` scope
    # @param relationship_type [String] the submitted relationship type
    # @param use_guardian_email [Object] the submitted checkbox value, truthy when chosen
    # @param use_guardian_phone [Object] the submitted checkbox value, truthy when chosen
    def initialize(dependent_params:, relationship_type:, use_guardian_email:, use_guardian_phone:)
      @attrs = dependent_params.to_h.with_indifferent_access
      @relationship_type = relationship_type
      @use_guardian_email = truthy?(use_guardian_email)
      @use_guardian_phone = truthy?(use_guardian_phone)
    end

    def to_s
      "#{VERSION}:#{OpenSSL::HMAC.hexdigest('SHA256', hmac_key, canonical_payload)}"
    end

    private

    # Sorted JSON preserves field boundaries and a stable field order.
    # A "key=value" join can confuse values that contain its separator with another field set.
    def canonical_payload
      JSON.generate(canonical_fields.sort.to_h)
    end

    def canonical_fields
      fields = {
        # Compare submitted names, relationship type, and phone type without normalization.
        'first_name' => @attrs[:first_name].to_s,
        'last_name' => @attrs[:last_name].to_s,
        'relationship_type' => @relationship_type.to_s,
        'phone_type' => @attrs[:phone_type].to_s,
        # These fields use the writer's canonical forms.
        'date_of_birth' => normalized_date(@attrs[:date_of_birth]),
        'newsletter_signup' => normalized_boolean(@attrs[:newsletter_signup]),
        'use_guardian_email' => @use_guardian_email ? '1' : '0',
        'use_guardian_phone' => @use_guardian_phone ? '1' : '0'
      }

      DISABILITY_FIELDS.each do |field|
        fields[field.to_s] = normalized_boolean(@attrs[field])
      end

      # Explicit guardian choices ignore submitted contact. A stale hidden value must not cause replay refusal.
      fields['email'] = User.normalize_email(@attrs[:email]).to_s unless @use_guardian_email
      fields['phone'] = User.normalize_phone(@attrs[:phone]).to_s unless @use_guardian_phone

      fields
    end

    # The model casts dates so MM/DD/YYYY and ISO values for the same day identify one request.
    def normalized_date(value)
      return '' if value.blank?

      holder = Users::Constituent.new
      holder.date_of_birth = value
      holder.date_of_birth&.iso8601.to_s
    end

    def normalized_boolean(value)
      truthy?(value) ? '1' : '0'
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value) ? true : false
    end

    def hmac_key
      Rails.application.key_generator.generate_key(HMAC_PURPOSE, 32)
    end
  end
end
