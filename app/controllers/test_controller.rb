# frozen_string_literal: true

# Test controller for handling test-specific routes
# Only available in test environment
class TestController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :enforce_required_mfa_enrollment
  skip_before_action :verify_authenticity_token

  # Simple endpoint for testing authentication status
  # Used by test helpers to verify authentication works correctly
  def auth_status
    status = if current_user
               { authenticated: true, user_id: current_user.id, email: current_user.email }
             else
               { authenticated: false }
             end

    respond_to do |format|
      format.html { render plain: status.to_json }
      format.json { render json: status }
    end
  end

  # Endpoint for setting test session variables (for Cuprite/browser tests)
  # Used by system test helpers to bypass 2FA
  def set_session
    if params[:skip_2fa] == 'true'
      session[:skip_2fa] = true
    elsif params.key?(:skip_2fa)
      session.delete(:skip_2fa)
    end

    render json: { session_set: true, skip_2fa: session[:skip_2fa] }
  end
end
