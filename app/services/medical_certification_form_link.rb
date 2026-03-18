# frozen_string_literal: true

require 'digest'

class MedicalCertificationFormLink
  PURPOSE = :medical_certification
  EXPIRATION = 14.days
  ALLOWED_STATUSES = %w[requested rejected].freeze

  class << self
    def signed_id_for(application)
      application.signed_id(
        purpose: PURPOSE,
        expires_in: EXPIRATION
      )
    end

    def find_application!(signed_id)
      Application.find_signed!(signed_id, purpose: PURPOSE)
    end

    def allowed_for?(application)
      ALLOWED_STATUSES.include?(application.medical_certification_status)
    end

    def consumed?(application, signed_id)
      Event.where(
        action: 'medical_certification_form_downloaded',
        auditable: application
      ).where("metadata->>'download_token_digest' = ?", token_digest(signed_id)).exists?
    end

    def consume!(application, signed_id)
      Event.create!(
        user: application.user,
        action: 'medical_certification_form_downloaded',
        auditable: application,
        metadata: {
          download_token_digest: token_digest(signed_id)
        }
      )
    end

    private

    def token_digest(signed_id)
      Digest::SHA256.hexdigest(signed_id.to_s)
    end
  end
end
