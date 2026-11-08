# frozen_string_literal: true

class RegistrationMailer < ApplicationMailer
  before_deliver :ensure_proof_is_active
  after_deliver :record_submission

  def email_verification
    @verification = params.fetch(:registration_verification)
    @delivery_subject = @verification
    raise DeliverySkipped.new(reason: 'verification_expired') unless @verification.active?

    template = find_text_template('registration_email_verification', locale: @verification.locale)
    verification_url = edit_registration_verification_url(token: @verification.proof_token, **CanonicalPublicUrlOptions.call)
    deadline = @verification.expires_at.in_time_zone
    expires_at = "#{I18n.l(deadline, format: :long, locale: @verification.locale)} #{deadline.zone}"
    send_email(@verification.email, template, { verification_url: verification_url, expires_at: expires_at },
               required_delivery: true, message_stream: 'outbound')
  end

  private

  def ensure_proof_is_active
    raise DeliverySkipped.new(reason: 'verification_expired') unless @verification.reload.active?
  end

  def record_submission
    @verification.update!(delivery_status: 'submitted')
  end
end
