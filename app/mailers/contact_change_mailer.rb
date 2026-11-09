# frozen_string_literal: true

class ContactChangeMailer < ApplicationMailer
  before_deliver :ensure_proof_is_current

  def verification
    change, role = request_and_role
    return noop_delivery(reason: 'expired') unless change.pending?

    template = find_text_template('contact_change_verification', locale: change.locale)
    url = contact_verification_url(purpose: role, token: change.proof_token(role), locale: change.locale,
                                   **CanonicalPublicUrlOptions.call)
    send_email(change.delivery_email(role), template,
               { confirmation_url: url, support_email: ProgramContact.support_email }, required_delivery: true)
  end

  def security_notice
    change, role = request_and_role
    template = find_text_template('contact_change_notice', locale: change.locale)
    message = I18n.t(role.end_with?('completed') ? 'contact_changes.mail_completed' : 'contact_changes.mail_requested', locale: change.locale)
    send_email(change.delivery_email(role), template, { message: message, support_email: ProgramContact.support_email }, required_delivery: true)
  end

  private

  def request_and_role
    change = params.fetch(:contact_change_request)
    role = params.fetch(:role).to_s
    raise ArgumentError, 'Unknown contact notice' unless ContactChangeRequest::DELIVERY_ROLES.include?(role)

    @delivery_subject = change
    [change, role]
  end

  def ensure_proof_is_current
    change, role = request_and_role
    return unless ContactChangeRequest::EMAIL_PROOFS.include?(role)
    return if change.reload.pending?

    raise DeliverySkipped.new(reason: 'verification_expired')
  end
end
