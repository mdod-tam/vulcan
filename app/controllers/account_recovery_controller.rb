# frozen_string_literal: true

class AccountRecoveryController < ApplicationController
  RECOVERY_REQUEST_RATE_LIMIT = 5
  RECOVERY_REQUEST_RATE_LIMIT_WINDOW = 1.hour

  skip_before_action :authenticate_user!, only: %i[new create confirmation]

  def new
    # Renders the form for requesting security key recovery
  end

  def create
    @user = User.find_by_login_identifier(account_recovery_contact)

    submit_recovery_request(@user) if @user.present?

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
    return if recovery_submission_rate_limited?(user)

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
    Rails.logger.error "Failed to submit recovery request for user #{user.id}: #{e.message}"
    nil
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
