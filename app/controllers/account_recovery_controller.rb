# frozen_string_literal: true

class AccountRecoveryController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[new create confirmation]
  around_action :with_public_request_locale, only: %i[new create confirmation]

  def new
    # Renders the form for requesting security key recovery
  end

  def create
    @account_recovery_contact = account_recovery_contact
    if (rate_limit_scope = pre_lookup_recovery_rate_limit_scope(@account_recovery_contact))
      log_unmatched_recovery_rate_limit(rate_limit_scope)
      return redirect_to_recovery_confirmation
    end

    @user = User.find_by_login_identifier(@account_recovery_contact)
    submit_recovery_request(@user) if @user.present?

    redirect_to_recovery_confirmation
  end

  def confirmation
    # Renders confirmation page
  end

  private

  def account_recovery_contact
    params[:contact].presence
  end

  def submit_recovery_request(user)
    if user_recovery_rate_limited?(user)
      log_recovery_attempt(user, 'rate_limited', reason: 'user_ip')
      return
    end

    user.with_lock do
      unless user.recovery_requests.pending.exists?
        recovery_request = user.recovery_requests.create!(
          status: 'pending',
          details: params[:details],
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        notify_admins_of_recovery_request!(recovery_request)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # Concurrent duplicate pending — treat as coalesced (partial unique index)
    nil
  rescue StandardError => e
    log_recovery_attempt(user, 'failed', error_class: e.class.name)
    Rails.logger.error "Failed to submit recovery request for user #{user.id}: #{e.message}"
    nil
  end

  def pre_lookup_recovery_rate_limit_scope(contact)
    return :ip if recovery_auth_rate_limited?(:ip)
    return :contact_ip if contact.present? && recovery_auth_rate_limited?(:contact_ip, submitted_contact: contact)

    nil
  end

  def user_recovery_rate_limited?(user)
    recovery_auth_rate_limited?(:user_ip, user: user)
  end

  def recovery_auth_rate_limited?(scope, submitted_contact: nil, user: nil)
    AuthRateLimit.check!(
      action: :account_recovery,
      scope: scope,
      request: request,
      submitted_contact: submitted_contact,
      user_id: user&.id
    )
    false
  rescue AuthRateLimit::ExceededError
    true
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

  def log_unmatched_recovery_rate_limit(rate_limit_scope)
    PublicAuditActor.log_audit(
      action: 'security_key_recovery_unmatched_rate_limited',
      metadata: recovery_audit_metadata.merge(rate_limit_scope: rate_limit_scope.to_s)
    )
  end

  def recovery_audit_metadata
    metadata = {
      request_ip_digest: AuthRateLimit.request_ip_digest(request),
      request_id: request.request_id
    }
    metadata[:submitted_contact_digest] = AuthRateLimit.contact_digest(@account_recovery_contact) if @account_recovery_contact.present?
    metadata
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

  def redirect_to_recovery_confirmation
    # We don't want to reveal if an email exists in our system.
    redirect_to account_recovery_confirmation_path(locale: public_request_locale_param)
  end
end
