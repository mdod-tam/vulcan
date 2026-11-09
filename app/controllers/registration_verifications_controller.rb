# frozen_string_literal: true

class RegistrationVerificationsController < ApplicationController
  skip_before_action :authenticate_user!, :check_password_change_required, :enforce_required_mfa_enrollment, only: %i[edit update]
  around_action :with_verified_request_locale
  before_action :require_verification

  def edit
    return redirect_existing_account if User.find_by_email(@verification.email)

    @user = Users::Constituent.new(email: @verification.email, locale: I18n.locale)
  end

  def update
    result = Users::RegistrationCompletion.new(token: params[:token], attributes: completion_params,
                                               actor: current_user).call
    @user = result.user
    case result.status
    when :complete then complete_sign_up
    when :existing then redirect_existing_account
    when :validation_failed then render :edit, status: :unprocessable_content
    when :invalid then invalid_link
    else
      redirect_to sign_in_path(locale: I18n.locale), status: :see_other,
                                                     alert: t('registration_verification.completion_failed')
    end
  end

  private

  def with_verified_request_locale(&)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @verification = RegistrationVerification.resolve(params[:token].to_s)
    I18n.with_locale(public_form_locale_param || @verification&.locale || public_request_locale, &)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("Registration verification unavailable: #{e.class.name}")
    invalid_link
  end

  def require_verification
    invalid_link unless @verification
  end

  def invalid_link
    redirect_to sign_up_path(locale: public_form_locale_param), status: :see_other,
                                                                alert: t('registration_verification.invalid_link')
  end

  def redirect_existing_account
    redirect_to sign_in_path(locale: I18n.locale), status: :see_other,
                                                   notice: t('registration_verification.existing_account')
  end

  def complete_sign_up
    welcome = Users::RegistrationConfirmationService.new(user: @user).call
    session_record = _create_and_set_session_cookie(
      @user, submitted_login_identifier: @user.email, submitted_password: completion_params[:password]
    )
    unless session_record
      return redirect_to sign_in_path(locale: I18n.locale), status: :see_other,
                                                            notice: t('registration_verification.completed_sign_in')
    end

    notice = welcome.success? ? 'portal_self_service.registrations.account_created' : 'registration_verification.completed_notice_failed'
    redirect_to welcome_path, status: :see_other, notice: t(notice)
  rescue StandardError => e
    Rails.logger.warn("Registration completed; follow-up failed: #{e.class.name}")
    redirect_to sign_in_path(locale: I18n.locale), status: :see_other,
                                                   notice: t('registration_verification.completed_sign_in')
  end

  def completion_params
    params.expect(user: [:password, :password_confirmation, :first_name, :last_name, :middle_initial,
                         :date_of_birth, :timezone, :locale, *Users::Constituent::DISABILITY_FLAGS,
                         :communication_preference, :newsletter_signup,
                         :physical_address_1, :physical_address_2, :city, :state, :zip_code])
  end
end
