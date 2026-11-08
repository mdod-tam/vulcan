# frozen_string_literal: true

class RegistrationsController < ApplicationController
  skip_before_action :authenticate_user!, :check_password_change_required, :enforce_required_mfa_enrollment, only: %i[new create]
  around_action :with_public_request_locale, only: %i[new create]
  before_action :prevent_registration_caching

  def new
    @verification = RegistrationVerification.new(locale: public_form_locale_param || I18n.default_locale)
  end

  def create
    @verification = RegistrationVerification.new(
      email: initiation_params[:email], locale: public_form_locale_param || I18n.default_locale,
      expires_at: RegistrationVerification::LIFETIME.from_now
    )
    return render :new, status: :unprocessable_content unless @verification.valid?

    issue_verification
    redirect_to sign_up_path(locale: public_form_locale_param), status: :see_other,
                                                                notice: t('registration_verification.check_email')
  end

  private

  def initiation_params
    params.expect(user: %i[email locale])
  end

  def issue_verification
    AuthRateLimit.check!(action: :registration, scope: :ip, request: request)
    AuthRateLimit.check!(action: :registration, scope: :contact, submitted_contact: @verification.email)
    denial, context = EmailDelivery.issuance('RegistrationMailer#email_verification')
    return if denial

    @verification.save!
    outcome = EmailDelivery.deliver_later(
      RegistrationMailer.with(registration_verification: @verification).email_verification,
      context: context
    )
    record_enqueue_outcome(outcome)
  rescue AuthRateLimit::ExceededError, ActiveRecord::ActiveRecordError, EmailDelivery::ConfigurationError => e
    Rails.logger.warn("Registration verification not issued: #{e.class.name}")
  rescue StandardError => e
    Rails.logger.warn("Registration verification delivery failed: #{e.class.name}")
    record_delivery_failure
  end

  def record_enqueue_outcome(outcome)
    @verification.with_lock do
      if @verification.delivery_status == 'pending'
        @verification.update!(delivery_status: outcome.in?(%i[queued deferred]) ? 'queued' : 'not_sent')
      end
    end
  end

  def record_delivery_failure
    @verification.update!(delivery_status: 'failed') if @verification.persisted?
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn('Registration verification failure state could not be recorded')
  end

  def prevent_registration_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
