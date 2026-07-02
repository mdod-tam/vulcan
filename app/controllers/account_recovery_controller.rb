# frozen_string_literal: true

require 'openssl'

class AccountRecoveryController < ApplicationController
  RECOVERY_REQUEST_RATE_LIMIT = 5
  RECOVERY_REQUEST_RATE_LIMIT_WINDOW = 1.hour

  skip_before_action :authenticate_user!, only: %i[new create confirmation]

  def new
    # Renders the form for requesting security key recovery
  end

  def create
    contact = account_recovery_contact
    contact_rate_limited = recovery_contact_rate_limited?(contact)
    @user = User.find_by_login_identifier(contact)

    if @user.present?
      if contact_rate_limited
        log_recovery_attempt(@user, 'rate_limited', reason: 'submitted_contact_ip')
      else
        submit_recovery_request(@user)
      end
    elsif contact_rate_limited
      log_unmatched_recovery_rate_limit(contact)
    end

    # We don't want to reveal if an email exists in our system
    # So we show the confirmation page regardless
    redirect_to account_recovery_confirmation_path
  end

  def confirmation
    # Renders confirmation page
  end

  private

  def account_recovery_contact
    params[:contact].presence
  end

  def submit_recovery_request(user)
    if recovery_submission_rate_limited?(user)
      log_recovery_attempt(user, 'rate_limited', reason: 'user_ip')
      return
    end

    user.with_lock do
      return if user.recovery_requests.pending.exists?

      recovery_request = user.recovery_requests.create!(
        status: 'pending',
        details: params[:details],
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
      notify_admins_of_recovery_request!(recovery_request)
    end
  rescue ActiveRecord::RecordNotUnique
    # Concurrent duplicate pending — treat as coalesced (partial unique index)
    nil
  rescue StandardError => e
    log_recovery_attempt(user, 'failed', error_class: e.class.name)
    Rails.logger.error "Failed to submit recovery request for user #{user.id}: #{e.message}"
    nil
  end

  def recovery_contact_rate_limited?(contact)
    count = Rails.cache.increment(recovery_contact_rate_limit_key(contact), 1,
                                  expires_in: RECOVERY_REQUEST_RATE_LIMIT_WINDOW)

    count.to_i > RECOVERY_REQUEST_RATE_LIMIT
  end

  def recovery_contact_rate_limit_key(contact)
    hashed_scope = Digest::SHA256.hexdigest(
      [submitted_recovery_contact_digest(contact), request_ip_digest].join(':')
    )
    "security_key_recovery_contact:#{hashed_scope}"
  end

  def recovery_submission_rate_limited?(user)
    count = Rails.cache.increment(recovery_submission_rate_limit_key(user), 1,
                                  expires_in: RECOVERY_REQUEST_RATE_LIMIT_WINDOW)

    count.to_i > RECOVERY_REQUEST_RATE_LIMIT
  end

  def recovery_submission_rate_limit_key(user)
    hashed_scope = Digest::SHA256.hexdigest("#{user.id}:#{request.remote_ip}")
    "security_key_recovery:#{hashed_scope}"
  end

  def log_recovery_attempt(user, status, metadata = {})
    AuditEventService.log(
      action: "security_key_recovery_request_#{status}",
      actor: user,
      auditable: user,
      metadata: recovery_audit_metadata.merge(metadata)
    )
  rescue StandardError => e
    Rails.logger.warn("Unable to audit security key recovery #{status} for user #{user.id}: #{e.message}")
  end

  def log_unmatched_recovery_rate_limit(contact)
    system_user = User.system_user
    AuditEventService.log(
      action: 'security_key_recovery_unmatched_rate_limited',
      actor: system_user,
      auditable: system_user,
      metadata: recovery_audit_metadata.merge(
        submitted_contact_digest: submitted_recovery_contact_digest(contact)
      )
    )
  rescue StandardError => e
    Rails.logger.warn("Unable to audit unmatched security key recovery rate limit: #{e.message}")
  end

  def recovery_audit_metadata
    {
      ip_address: request.remote_ip,
      request_id: request.request_id
    }
  end

  def submitted_recovery_contact_digest(contact)
    OpenSSL::HMAC.hexdigest('SHA256', recovery_contact_digest_secret, normalized_recovery_contact(contact))
  end

  def normalized_recovery_contact(contact)
    normalized = contact.to_s.strip
    return 'blank' if normalized.blank?
    return User.normalize_email(normalized) if User.login_identifier_looks_like_email?(normalized)

    User.normalize_phone(normalized).to_s
  end

  def recovery_contact_digest_secret
    Rails.application.key_generator.generate_key('account-recovery-submitted-contact', 32)
  end

  def request_ip_digest
    Digest::SHA256.hexdigest(request.remote_ip.to_s)
  end

  def notify_admins_of_recovery_request!(recovery_request)
    admin_count = 0
    notifications_created = 0

    User.admins.find_each do |admin|
      admin_count += 1
      notification = NotificationService.build
                                        .type('security_key_recovery_requested')
                                        .recipient(admin)
                                        .actor(recovery_request.user)
                                        .notifiable(recovery_request)
                                        .metadata(
                                          recovery_request_id: recovery_request.id,
                                          requester_identifier: recovery_request.user.mfa_account_name
                                        )
                                        .channel(:email)
                                        .deliver(false)
                                        .create_and_deliver!

      raise 'Failed to create admin notification for recovery request' unless notification.respond_to?(:persisted?) && notification.persisted?

      notifications_created += 1
    end

    raise 'No admin recipients configured for recovery notification' if admin_count.zero?
    raise 'Failed to create admin notifications for recovery request' if notifications_created.zero?
  end
end
