# frozen_string_literal: true

class WelcomeController < ApplicationController
  before_action :authenticate_user!

  # GET /welcome
  # First-time welcome page after registration
  def index
    @user = current_user
    @has_webauthn = @user.webauthn_credentials.exists?
    @has_totp = @user.totp_credentials.exists?
    @has_sms = @user.sms_credentials.verified.exists?
    @has_second_factor = @user.second_factor_enabled?
    @dashboard_path = _dashboard_for(@user)

    # If user already has 2FA set up, redirect to dashboard
    return unless @has_second_factor && params[:force] != 'true'

    redirect_to @dashboard_path
  end
end
