# frozen_string_literal: true

class AccountRecoveryController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[new create confirmation]

  def new
    # Renders the form for requesting security key recovery
  end

  def create
    @user = User.find_by_login_identifier(account_recovery_contact)

    if @user.present?
      # Create a recovery request record
      recovery_request = create_recovery_request(@user)

      # Notify administrators of the recovery request
      notify_admins_of_recovery_request(recovery_request)
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

  def create_recovery_request(user)
    # Record the recovery request in the database
    RecoveryRequest.create!(
      user: user,
      status: 'pending',
      details: params[:details],
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )

    # Return the recovery request object
  end

  def notify_admins_of_recovery_request(recovery_request)
    User.admins.find_each do |admin|
      NotificationService.create_and_deliver!(
        type: 'security_key_recovery_requested',
        recipient: admin,
        actor: recovery_request.user,
        notifiable: recovery_request,
        metadata: {
          recovery_request_id: recovery_request.id,
          requester_identifier: recovery_request.user.mfa_account_name
        },
        deliver: false
      )
    end
  rescue StandardError => e
    Rails.logger.error "Failed to notify admins of recovery request #{recovery_request.id}: #{e.message}"
  end
end
