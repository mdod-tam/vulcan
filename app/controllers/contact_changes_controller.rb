# frozen_string_literal: true

class ContactChangesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[verification confirm_email]
  skip_before_action :check_password_change_required, :enforce_required_mfa_enrollment, only: %i[verification confirm_email]
  around_action :with_contact_request_locale
  before_action :private_response
  before_action :load_owned_request, only: %i[show destroy resend verify_sms complete]

  def show; end

  def new
    return require_recent_identity unless current_session&.freshly_authenticated?(user: current_user)

    @contact_change = ContactChangeRequest.new(kind: 'email', phone_type: 'text')
  end

  def create
    @contact_change = ContactChangeRequest.new(contact_params)
    contact_budget!(@contact_change.proposed_value)
    @contact_change = writer.request!(contact_params)
    @contact_change.enqueue_deliveries!
    send_requested_sms if @contact_change.sms?
    redirect_to contact_change_path(@contact_change), notice: t('contact_changes.requested'), status: :see_other
  rescue Session::AuthenticationRequired
    require_recent_identity
  rescue ActiveRecord::RecordInvalid => e
    @contact_change = e.record if e.record.is_a?(ContactChangeRequest)
    flash.now[:alert] = t('contact_changes.invalid')
    render :new, status: :unprocessable_content
  rescue ContactChangeRequest::Refused, AuthRateLimit::ExceededError, ActiveRecord::RecordNotUnique
    flash.now[:alert] = t('contact_changes.unavailable')
    render :new, status: :unprocessable_content
  end

  def verification
    @contact_change = ContactChangeRequest.find_for_proof(params[:token], params[:purpose])
    return render :invalid, status: :unprocessable_content unless @contact_change

    field = params[:purpose] == 'old_email' ? :old_confirmed_at : :new_confirmed_at
    render :confirmed if @contact_change.public_send(field).present?
  end

  def confirm_email
    @contact_change = ContactChangeRequest.find_for_proof(params[:token], params[:purpose])
    raise ContactChangeRequest::Refused unless @contact_change

    User.transaction do
      user = User.lock_for_merge_integrity!(@contact_change.user_id).fetch(@contact_change.user_id)
      @contact_change.lock!
      @contact_change.require_current!(locked_user: user)
      field = params[:purpose] == 'old_email' ? :old_confirmed_at : :new_confirmed_at
      raise ContactChangeRequest::Refused if field == :old_confirmed_at && !@contact_change.old_confirmation_required?
      raise ContactChangeRequest::Refused if @contact_change.public_send(field).present?

      @contact_change.update!(field => Time.current)
      PublicAuditActor.log_audit(action: 'account_contact_email_confirmed', auditable: user,
                                 metadata: { operation_id: "contact-change:#{@contact_change.id}:#{params[:purpose]}",
                                             contact_change_request_id: @contact_change.id, proof: params[:purpose] })
    end
    redirect_to contact_verification_path(purpose: params[:purpose], token: params[:token], locale: I18n.locale), status: :see_other
  rescue ContactChangeRequest::Refused, ActiveSupport::MessageVerifier::InvalidSignature
    render :invalid, status: :unprocessable_content
  end

  def verify_sms
    writer.confirm_sms!(@contact_change, code: params[:code])
    redirect_to contact_change_path(@contact_change), notice: t('contact_changes.confirmed'), status: :see_other
  rescue Session::AuthenticationRequired
    require_recent_identity
  rescue ContactChangeRequest::Refused
    redirect_to contact_change_path(@contact_change), alert: t('contact_changes.verification_unavailable'), status: :see_other
  end

  def complete
    return unless complete_contact

    clear_session_authentication
    notice = enqueue_completed_notices ? 'contact_changes.completed' : 'contact_changes.completed_notice_failed'
    redirect_to sign_in_path, notice: t(notice), status: :see_other
  end

  def resend
    contact_budget!(@contact_change.proposed_value)
    writer.resend!(@contact_change)
    @contact_change.enqueue_deliveries!
    send_requested_sms if @contact_change.sms?
    redirect_to contact_change_path(@contact_change), notice: t('contact_changes.requested'), status: :see_other
  rescue Session::AuthenticationRequired
    require_recent_identity
  rescue ContactChangeRequest::Refused, AuthRateLimit::ExceededError
    redirect_to contact_change_path(@contact_change), alert: t('contact_changes.unavailable'), status: :see_other
  end

  def destroy
    User.transaction do
      user = User.lock_for_merge_integrity!(current_user).fetch(current_user.id)
      current_session.require_live!(token: presented_session_token, user: user)
      @contact_change.lock!
      @contact_change.update!(canceled_at: Time.current) if @contact_change.completed_at.nil?
      AuditEventService.log(action: 'account_contact_change_canceled', actor: user, auditable: user,
                            metadata: { contact_change_request_id: @contact_change.id })
    end
    redirect_to edit_profile_path, notice: t('contact_changes.canceled'), status: :see_other
  rescue Session::AuthenticationRequired
    redirect_to sign_in_path, alert: t('alerts.sign_in_required'), status: :see_other
  end

  private

  def complete_contact
    writer.complete!(@contact_change)
    true
  rescue Session::AuthenticationRequired
    require_recent_identity
    false
  rescue ContactChangeRequest::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to contact_change_path(@contact_change), alert: t('contact_changes.unavailable'), status: :see_other
    false
  end

  def enqueue_completed_notices
    @contact_change.enqueue_deliveries!
    @contact_change.reload.completion_notices_queued?
  rescue StandardError => e
    Rails.logger.warn("Contact completion notice enqueue failed: #{e.class.name}")
    false
  end

  def with_contact_request_locale(&)
    locale = if action_name.in?(%w[verification confirm_email])
               public_request_locale
             else
               @contact_change&.locale || current_user.effective_message_locale
             end
    I18n.with_locale(locale, &)
  end

  def writer
    Users::ContactChange.new(user: current_user, actor: current_user, session: current_session, token: presented_session_token)
  end

  def load_owned_request
    @contact_change = ContactChangeRequest.where(user_id: current_user.id).find(params.expect(:id))
  end

  def require_recent_identity
    destination = @contact_change&.persisted? ? contact_change_path(@contact_change) : new_contact_change_path
    redirect_to new_reauthentication_path(return_to: destination), alert: t('reauthentication.required'), status: :see_other
  end

  def contact_params
    params.expect(contact_change_request: %i[kind proposed_value phone_type])
  end

  def contact_budget!(contact)
    AuthRateLimit.check!(action: :contact_change, scope: :ip, request: request)
    AuthRateLimit.check!(action: :contact_change, scope: :user_ip, request: request, user_id: current_user.id)
    return unless contact.present? && AuthRateLimit.contact_digest(contact) != 'blank'

    AuthRateLimit.check!(action: :contact_change, scope: :contact, submitted_contact: contact)
  end

  def send_requested_sms
    writer.send_sms!(@contact_change)
  rescue ContactChangeRequest::Refused
    flash[:alert] = t('contact_changes.verification_unavailable')
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
