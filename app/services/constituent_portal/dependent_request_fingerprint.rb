# frozen_string_literal: true

module ConstituentPortal
  # Canonical fingerprint of one portal dependent-creation request.
  #
  # Paired with `portal_creation_key`, this is what makes a replay decision truthful. The key
  # answers "have I seen this request id"; the fingerprint answers "is this the same operation".
  # Without it a resubmission carrying a spent key but changed input would be reported as "already
  # added" while the change was silently dropped -- the guardian would have been told their
  # submission succeeded, which for a changed email or phone is simply false.
  #
  # Covers everything semantically submitted, because a replay key means "repeat this creation
  # operation": any change to what would be persisted must refuse rather than be discarded. That is
  # not friction on the normal path -- fields stay freely editable after a *failed* submission,
  # since nothing was persisted and the key is still unspent. It only refuses once that exact key
  # has already completed a different operation.
  #
  # Two properties this object has to hold, both of which a looser implementation quietly breaks:
  #
  # 1. **It normalizes only what the writer normalizes.** Names and relationship type are stored
  #    verbatim, so "Jane" and " jane " are *different persisted records* and must fingerprint
  #    differently. Case- or whitespace-folding them would let a real change replay as a no-op.
  #    Date of birth, email, phone, and booleans are canonicalized because the writer canonicalizes
  #    them, so two spellings of one stored value are genuinely the same request.
  #
  # 2. **It depends on submitted intent alone, never on the guardian record.** The contact strategy
  #    is read from the explicit `use_guardian_*` choices rather than re-derived by comparing
  #    submitted contact against the guardian's current email or phone. Re-deriving would make the
  #    fingerprint a function of mutable state: the guardian edits their own email, and a
  #    byte-identical replay suddenly hashes differently and is refused as stale.
  #
  # Deliberately excluded: transport and derived values. CSRF tokens and submit labels are not
  # input; the creation key is the thing being looked up; synthetic contact values and guardian
  # contact snapshots are *generated* rather than submitted; and the contact fields a guardian
  # strategy ignores are never persisted, so a stale value left in a hidden input must not count.
  class DependentRequestFingerprint
    # Bumping this invalidates every stored fingerprint rather than silently matching rows built
    # under a different canonical form. A comparison that quietly changed meaning is exactly the
    # failure this object exists to prevent.
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

    # JSON of a sorted hash, so field boundaries are escaped by the serializer. A hand-rolled
    # "key=value" join has no such guarantee: a value containing the separator can reproduce another
    # field set's payload, and two different requests would then share a fingerprint.
    def canonical_payload
      JSON.generate(canonical_fields.sort.to_h)
    end

    def canonical_fields
      fields = {
        # Stored verbatim by the writer, so compared verbatim here.
        'first_name' => @attrs[:first_name].to_s,
        'last_name' => @attrs[:last_name].to_s,
        'relationship_type' => @relationship_type.to_s,
        'phone_type' => @attrs[:phone_type].to_s,
        # Canonicalized by the writer, so canonicalized here.
        'date_of_birth' => normalized_date(@attrs[:date_of_birth]),
        'newsletter_signup' => normalized_boolean(@attrs[:newsletter_signup]),
        'use_guardian_email' => @use_guardian_email ? '1' : '0',
        'use_guardian_phone' => @use_guardian_phone ? '1' : '0'
      }

      DISABILITY_FIELDS.each do |field|
        fields[field.to_s] = normalized_boolean(@attrs[field])
      end

      # Only when the dependent owns the value. Under a guardian choice the submitted field is
      # ignored by the writer, so counting it would refuse a replay over something never stored.
      fields['email'] = User.normalize_email(@attrs[:email]).to_s unless @use_guardian_email
      fields['phone'] = User.normalize_phone(@attrs[:phone]).to_s unless @use_guardian_phone

      fields
    end

    # Cast through the model rather than parsed here, so this follows the same interpretation the
    # writer stores: the portal's MM/DD/YYYY and an ISO value for the same day are one request.
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
