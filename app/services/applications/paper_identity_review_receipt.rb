# frozen_string_literal: true

module Applications
  # A short-lived receipt of the facts shown to staff. Cases own completed decisions.
  class PaperIdentityReviewReceipt
    PURPOSE = 'paper-identity-review-v2'
    MAX_AGE = 30.minutes
    Facts = Data.define(:context, :admin, :identity, :candidates, :reasons)
    Result = Data.define(:valid, :reason) do
      def valid? = valid
    end

    class << self
      def issue(facts, issued_at: Time.current)
        verifier.generate(fingerprint(facts), purpose: PURPOSE, expires_at: issued_at + MAX_AGE)
      end

      def verify(receipt, facts)
        actual = verifier.verified(receipt.to_s, purpose: PURPOSE)
        valid = actual.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(actual, fingerprint(facts))
        Result.new(valid: valid, reason: valid ? nil : :mismatched)
      end

      def identity_fingerprint(identity)
        digest(identity.to_h.transform_keys(&:to_s).sort.to_h)
      end

      private

      def fingerprint(facts)
        candidates = Array(facts.candidates).map { |row| row.to_h.transform_keys(&:to_s).sort.to_h }
        digest([facts.context, facts.admin&.id, identity_fingerprint(facts.identity),
                candidates.sort_by { |row| row.fetch('id').to_i }, Array(facts.reasons).map(&:to_s).sort])
      end

      def digest(value)
        key = Rails.application.key_generator.generate_key(PURPOSE, 32)
        OpenSSL::HMAC.hexdigest('SHA256', key, JSON.generate(value))
      end

      def verifier
        Rails.application.message_verifier(PURPOSE)
      end
    end
  end
end
