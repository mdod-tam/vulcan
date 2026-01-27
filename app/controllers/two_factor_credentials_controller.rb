# frozen_string_literal: true

# Handles management of two-factor authentication credentials.
#
# This controller is responsible for:
# - Creating new credentials (WebAuthn, TOTP, SMS)
# - Verifying and confirming credentials during setup
# - Deleting existing credentials
# - Managing credential-specific flows (SMS verification, WebAuthn options)
class TwoFactorCredentialsController < ApplicationController
  include TwoFactorVerification
  include TurboStreamResponseHandling

  before_action :authenticate_user!

  # GET /two_factor_authentication/credentials/webauthn/options
  def webauthn_creation_options
    # Get authenticator type from params (platform for biometric, cross-platform for security keys)
    authenticator_type = params[:authenticator_type]

    # Generate WebAuthn options - using update_column to bypass validations
    current_user.update_column(:webauthn_id, WebAuthn.generate_user_id) if current_user.webauthn_id.blank?

    # Create options based on authenticator type
    create_options = if authenticator_type == 'platform'
                       build_platform_create_options
                     else
                       build_cross_platform_create_options
                     end

    # Store challenge in session using the standardized helper
    TwoFactorAuth.store_challenge(
      session,
      :webauthn,
      create_options.challenge,
      { authenticator_type: authenticator_type }
    )

    render json: create_options
  end

  # GET /two_factor_authentication/credentials/:type/new
  def new_credential
    @type = params[:type]

    case @type
    when 'webauthn'
      render 'webauthn_credentials/new'
    when 'totp'
      # Generate or retrieve validated secret - never use params directly
      @secret = get_validated_totp_secret(params[:secret])

      # Store the secret in the session
      TwoFactorAuth.store_challenge(
        session,
        :totp,
        nil, # TOTP doesn't need a challenge, just metadata
        { secret: @secret }
      )

      # Generate QR code with validated secret
      generate_totp_qr_code

      render 'totp_credentials/new'
    when 'sms'
      render 'sms_credentials/new'
    else
      handle_error_response(
        html_redirect_path: setup_two_factor_authentication_path,
        error_message: 'Invalid credential type'
      )
    end
  end

  # POST /two_factor_authentication/credentials/:type
  def create_credential
    @type = params[:type]

    case @type
    when 'webauthn'
      create_webauthn_credential
    when 'totp'
      create_totp_credential
    when 'sms'
      create_sms_credential
    else
      handle_error_response(
        html_redirect_path: setup_two_factor_authentication_path,
        error_message: 'Invalid credential type'
      )
    end
  end

  # GET /two_factor_authentication/credentials/:type/success
  def credential_success
    @type = params[:type]

    case @type
    when 'webauthn'
      render 'webauthn_credentials/create_success'
    when 'totp'
      render 'totp_credentials/create_success'
    when 'sms'
      render 'sms_credentials/confirm_success'
    else
      redirect_to edit_profile_path
    end
  end

  # GET /two_factor_authentication/credentials/sms/:id/verify
  def verify_sms_credential
    @credential = current_user.sms_credentials.find_by(id: params[:id])

    unless @credential
      handle_error_response(
        html_redirect_path: new_credential_two_factor_authentication_path(type: 'sms'),
        error_message: 'SMS credential not found'
      )
      return
    end

    render 'sms_credentials/verify'
  end

  # POST /two_factor_authentication/credentials/sms/:id/confirm
  def confirm_sms_credential
    @credential = find_sms_credential_for_confirmation
    return unless @credential

    handle_sms_confirmation_result
  end

  # POST /two_factor_authentication/credentials/sms/:id/resend
  def resend_sms_code
    @credential = current_user.sms_credentials.find_by(id: params[:id])

    unless @credential
      handle_error_response(
        html_redirect_path: new_credential_two_factor_authentication_path(type: 'sms'),
        error_message: 'SMS credential not found'
      )
      return
    end

    if send_sms_verification_code(@credential)
      handle_success_response(
        html_redirect_path: verify_sms_credential_two_factor_authentication_path(id: @credential.id),
        html_message: 'A new verification code has been sent',
        turbo_message: 'A new verification code has been sent'
      )
    else
      handle_error_response(
        html_redirect_path: verify_sms_credential_two_factor_authentication_path(id: @credential.id),
        error_message: 'Could not send verification code'
      )
    end
  end

  # DELETE /two_factor_authentication/credentials/:type/:id
  def destroy_credential
    @type = params[:type]
    credential, credential_name = find_credential_for_destruction

    return unless credential

    destroy_and_log_credential(credential, credential_name)
  end

  private

  # Find credential and name for destruction
  def find_credential_for_destruction
    credential_configs = {
      'webauthn' => { relation: :webauthn_credentials, name: 'Security key' },
      'totp' => { relation: :totp_credentials, name: 'Authenticator app' },
      'sms' => { relation: :sms_credentials, name: 'SMS verification' }
    }

    config = credential_configs[@type]
    unless config
      redirect_to edit_profile_path, alert: 'Invalid credential type'
      return [nil, nil]
    end

    credential = current_user.send(config[:relation]).find_by(id: params[:id])
    unless credential
      redirect_to edit_profile_path, alert: "#{config[:name]} not found"
      return [nil, nil]
    end

    [credential, config[:name]]
  end

  # Destroy credential and log the action
  # Delegates success/failure handling to smaller helpers to satisfy RuboCop ABC limits.
  def destroy_and_log_credential(credential, credential_name)
    if credential.destroy
      handle_credential_destruction_success(credential_name, credential)
    else
      handle_credential_destruction_failure(credential_name, credential.id)
    end
  end

  # Single-responsibility private helper methods
  # Handles the HTML / Turbo Stream response and logging when a credential
  # is successfully destroyed.
  #
  # @param credential_name [String] Friendly name (e.g., "Authenticator app")
  # @param credential [ApplicationRecord] The destroyed credential instance
  def handle_credential_destruction_success(credential_name, credential)
    success_message = "#{credential_name} removed successfully"

    Rails.logger.info(
      "[2FA_CREDENTIAL] #{credential_name} (ID: #{credential.id}) removed successfully for user #{current_user.id}"
    )

    respond_to do |format|
      format.html { redirect_to edit_profile_path, notice: success_message }
      format.turbo_stream do
        flash.now[:notice] = success_message
        render turbo_stream: [
          turbo_stream.update('flash', partial: 'shared/flash'),
          turbo_stream.remove(credential)
        ]
      end
    end
  end

  # Handles logging and error response when credential destruction fails.
  #
  # @param credential_name [String]
  # @param credential_id [Integer]
  def handle_credential_destruction_failure(credential_name, credential_id)
    Rails.logger.error(
      "[2FA_CREDENTIAL] Failed to remove #{credential_name.downcase} (ID: #{credential_id}) for user #{current_user.id}"
    )

    handle_error_response(
      html_redirect_path: edit_profile_path,
      error_message: "Failed to remove #{credential_name.downcase}"
    )
  end

  def create_webauthn_credential
    nested_params = process_webauthn_params
    webauthn_credential = create_webauthn_from_params(nested_params)

    verify_webauthn_challenge(webauthn_credential)
    credential = save_webauthn_credential(webauthn_credential)

    handle_webauthn_success(credential)
  rescue WebAuthn::Error => e
    handle_webauthn_error(e, 'verification')
  rescue StandardError => e
    handle_webauthn_error(e, 'creation')
  end

  def create_totp_credential
    @secret = totp_secret_from_session
    if totp_setup_code_valid?
      handle_totp_credential_success
    else
      handle_totp_verification_failure
    end
  end

  def create_sms_credential
    phone = params[:phone_number]

    return render_invalid_phone_error unless valid_phone_number?(phone)

    @credential = build_sms_credential(phone)

    if @credential.save
      unless @credential.errors.empty?
        Rails.logger.error("[2FA_CREDENTIAL] SMS credential save failed due to validation errors: #{@credential.errors.full_messages.join(', ')}")
      end

      handle_sms_credential_success
    else
      handle_sms_credential_failure
    end
  end

  def handle_totp_verification_failure
    message = TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
    log_totp_setup_failure(message)

    # Regenerate the QR code so the user can try again without losing the setup flow.
    regenerate_qr_code_for_failed_setup

    # Use the shared error handler to render the form again with an alert.
    handle_error_response(html_render_action: 'totp_credentials/new', error_message: message)
  end

  def regenerate_qr_code_for_failed_setup
    # Ensure @secret is validated from params or session
    challenge_data = TwoFactorAuth.retrieve_challenge(session)
    raw_secret = params[:secret] || challenge_data[:metadata]&.dig(:secret)
    @secret = validate_base32_secret(raw_secret) # Always validate before use

    unless @secret
      Rails.logger.error('[2FA_CREDENTIAL] Invalid or missing secret when regenerating QR code for failed setup.')
      # Generate a new valid secret if the old one is invalid
      @secret = ROTP::Base32.random
    end
    generate_totp_qr_code
  end

  # SMS credential creation helper methods
  def render_invalid_phone_error
    handle_error_response(
      html_render_action: 'sms_credentials/new',
      error_message: 'Invalid phone number format. Please try again.'
    )
  end

  def build_sms_credential(phone)
    current_user.sms_credentials.new(
      phone_number: phone,
      last_sent_at: Time.current # Set a default value to satisfy NOT NULL constraint
    )
  end

  def handle_sms_credential_success
    log_sms_credential_created
    Rails.logger.info("[2FA_CREDENTIAL] redirecting to url: #{verify_sms_credential_two_factor_authentication_path(id: @credential.id)}")
    send_verification_or_handle_failure
  end

  def handle_sms_credential_failure
    log_sms_credential_save_failure
    handle_error_response(
      html_render_action: 'sms_credentials/new',
      error_message: "Could not set up SMS authentication: #{@credential.errors.full_messages.join(', ')}"
    )
  end

  def log_sms_credential_created
    Rails.logger.info("[2FA_CREDENTIAL] SMS credential created (pending verification) for user #{current_user.id}, credential ID: #{@credential.id}")
  end

  def send_verification_or_handle_failure
    Rails.logger.info("[SMS_DEBUG] About to send SMS for credential #{@credential.id}")
    sms_result = send_sms_verification_code(@credential)
    Rails.logger.info("[SMS_DEBUG] SMS send result: #{sms_result}")

    if sms_result
      Rails.logger.info('[SMS_DEBUG] SMS sent successfully, redirecting to verification')
      handle_success_response(
        html_redirect_path: verify_sms_credential_two_factor_authentication_path(id: @credential.id),
        html_message: 'Verification code sent.',
        turbo_message: 'Verification code sent.',
        turbo_redirect_path: verify_sms_credential_two_factor_authentication_path(id: @credential.id)
      )
    else
      Rails.logger.error('[SMS_DEBUG] SMS sending failed, staying on form')
      log_sms_send_failure
      handle_error_response(
        html_render_action: 'sms_credentials/new',
        error_message: 'Could not send verification code'
      )
    end
  end

  def log_sms_send_failure
    Rails.logger.error("[2FA_CREDENTIAL] Failed to send SMS verification code during setup for user #{current_user.id}, credential ID: #{@credential.id}")
  end

  def log_sms_credential_save_failure
    Rails.logger.warn("[2FA_CREDENTIAL] Failed to save SMS credential for user #{current_user.id}: #{@credential.errors.full_messages.join(', ')}")
  end

  # TOTP verification failure helper methods
  def log_totp_setup_failure(message)
    Rails.logger.warn("[2FA_CREDENTIAL] TOTP credential setup verification failed for user #{current_user.id}: #{message}")
    TwoFactorAuth.log_verification_failure(current_user.id, :totp, 'Invalid code during setup')
  end

  def respond_to_totp_failure_formats
    respond_to do |format|
      format.html { handle_totp_html_failure }
      format.turbo_stream { handle_totp_turbo_failure }
    end
  end

  def handle_totp_html_failure
    handle_error_response(
      html_redirect_path: new_credential_two_factor_authentication_path(type: 'totp', secret: @secret),
      error_message: TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
    )
  end

  def handle_totp_turbo_failure
    regenerate_qr_code_for_failed_setup
    render :create_credential, status: :unprocessable_content
  end

  # TOTP credential creation helper methods
  def totp_secret_from_session
    challenge_data = TwoFactorAuth.retrieve_challenge(session)
    challenge_data[:metadata]&.dig(:secret) || params[:secret]
  end

  def totp_setup_code_valid?
    totp = ROTP::TOTP.new(@secret)
    totp.verify(params[:code], drift_behind: 30, drift_ahead: 30)
  end

  def handle_totp_credential_success
    # Create the credential record and clear the session challenge first.
    credential = create_totp_credential_record
    log_totp_credential_created(credential)
    TwoFactorAuth.clear_challenge(session)

    success_path = credential_success_two_factor_authentication_path(type: 'totp')
    success_message = 'Authenticator app registered successfully'

    respond_to do |format|
      format.html { redirect_to success_path, notice: success_message }
      format.turbo_stream do
        flash[:notice] = success_message
        redirect_to success_path, status: :see_other
      end
    end
  end

  def create_totp_credential_record
    current_user.totp_credentials.create!(
      secret: @secret,
      nickname: params[:nickname].presence || 'Authenticator App',
      last_used_at: Time.current
    )
  end

  def log_totp_credential_created(credential)
    Rails.logger.info("[2FA_CREDENTIAL] TOTP credential created for user #{current_user.id}, credential ID: #{credential.id}")
  end

  # SMS confirmation helper methods
  def find_sms_credential_for_confirmation
    credential = current_user.sms_credentials.find_by(id: params[:id])
    unless credential
      handle_error_response(
        html_redirect_path: new_credential_two_factor_authentication_path(type: 'sms'),
        error_message: 'SMS credential not found'
      )
      return nil
    end
    credential
  end

  def handle_sms_confirmation_result
    code = params[:code]

    # SMS setup verification uses the credential's own verify_code method
    # This differs from login verification which uses the TwoFactorVerification concern
    # During setup, the user is already authenticated, so we verify directly against the credential
    if @credential.verify_code(code)
      respond_to do |format|
        format.html { redirect_to_sms_confirmation_success }
        format.turbo_stream { redirect_to_sms_confirmation_success }
      end
    else
      message = TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
      respond_to do |format|
        format.html { handle_sms_confirmation_failure(message) }
        format.turbo_stream { handle_sms_confirmation_failure(message) }
      end
    end
  end

  def redirect_to_sms_confirmation_success
    handle_success_response(
      html_redirect_path: credential_success_two_factor_authentication_path(type: 'sms'),
      html_message: 'Phone number verified successfully',
      turbo_message: 'Phone number verified successfully'
    )
  end

  def handle_sms_confirmation_failure(message)
    handle_error_response(
      html_render_action: 'sms_credentials/verify',
      error_message: message
    )
  end

  # WebAuthn credential creation helper methods
  def process_webauthn_params
    params.expect(
      two_factor_credential: [:id, :rawId, :type, :authenticatorAttachment,
                              { response: [:clientDataJSON, :attestationObject, { transports: [] }],
                                clientExtensionResults: {} }]
    )
  end

  def create_webauthn_from_params(nested_params)
    WebAuthn::Credential.from_create(nested_params)
  end

  def verify_webauthn_challenge(webauthn_credential)
    challenge_data = TwoFactorAuth.retrieve_challenge(session)
    challenge = challenge_data[:challenge]
    webauthn_credential.verify(challenge)
  end

  def save_webauthn_credential(webauthn_credential)
    credential = current_user.webauthn_credentials.create!(
      external_id: webauthn_credential.id,
      nickname: params[:credential_nickname].presence || 'Security Key',
      public_key: webauthn_credential.public_key,
      sign_count: webauthn_credential.sign_count
    )

    TwoFactorAuth.clear_challenge(session)
    log_webauthn_credential_created(credential)
    credential
  end

  def log_webauthn_credential_created(credential)
    Rails.logger.info("[2FA_CREDENTIAL] WebAuthn credential created for user #{current_user.id}, credential ID: #{credential.id}")
  end

  def handle_webauthn_success(credential)
    render json: {
      status: 'ok',
      credential: {
        id: credential.id,
        nickname: credential.nickname,
        created_at: credential.created_at
      },
      redirect_url: credential_success_two_factor_authentication_path(type: 'webauthn')
    }
  end

  def handle_webauthn_error(error, error_type)
    case error_type
    when 'verification'
      Rails.logger.warn("[2FA_CREDENTIAL] WebAuthn credential verification failed for user #{current_user.id}: #{error.message}")
      render json: { error: "Verification failed: #{error.message}" }, status: :unprocessable_content
    when 'creation'
      Rails.logger.error("[2FA_CREDENTIAL] Error creating WebAuthn credential for user #{current_user.id}: #{error.message}")
      render json: { error: "Error creating credential: #{error.message}" }, status: :unprocessable_content
    end
  end
end
