# frozen_string_literal: true

class DocumentScansController < ApplicationController
  prepend_before_action :private_response
  skip_before_action :authenticate_user!, :check_password_change_required, :enforce_required_mfa_enrollment, if: :secure_context?
  before_action :set_owner
  around_action :scan_locale

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def index
    purpose, slot = allowed_slot!
    scan = owned_scans.recoverable.where(purpose: purpose, slot: slot, form_context: form_context).order(id: :desc).first
    render json: scan && scan_json(scan)
  end

  def show
    render json: scan_json(owned_scans.find(params.expect(:id)))
  end

  def create
    purpose, slot = allowed_slot!
    scan = DocumentScan.stage!(input: params[:file], purpose: purpose, slot: slot,
                               user: @scan_user, secure_form: @secure_form, form_context: form_context)
    render json: scan_json(scan), status: :accepted
  rescue UploadedDocument::Refused => e
    render json: { message: e.user_message }, status: :unprocessable_content
  rescue DocumentScan::LimitExceeded
    render json: { message: t('documents.scan.limit_reached') }, status: :too_many_requests
  end

  def destroy
    owned_scans.find(params.expect(:id)).update!(dismissed_at: Time.current)
    head :no_content
  end

  private

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def secure_context? = params[:secure_form_type].present?

  # Status polling must not keep an unattended session alive.
  def track_session_activity? = !request.get?

  def set_owner
    if secure_context?
      @secure_form = case params[:secure_form_type]
                     when 'proof' then SecureRequestForm.from_public_token(params[:token])
                     when 'certification' then MedicalProviderSecureRequestForm.from_public_token(params[:token])
                     when 'w9' then VendorSecureRequestForm.from_public_token(params[:token])
                     end
      head :not_found unless @secure_form&.active_for_public_use? && secure_kind_matches?
    else
      @scan_user = current_user
      head :not_found unless @scan_user&.public_login_active? && (@scan_user.admin? || @scan_user.constituent? || @scan_user.vendor?)
    end
  end

  def secure_kind_matches?
    case params[:secure_form_type]
    when 'proof'
      type = SecureRequestForm::PROOF_TYPES_BY_KIND[@secure_form.kind]
      type && @secure_form.application.proof_requestable_via_secure_form?(type)
    when 'certification' then @secure_form.kind_certification_upload?
    when 'w9' then @secure_form.kind_w9_upload? && @secure_form.vendor.w9_requestable_via_secure_form?
    end
  end

  def allowed_slot!
    purpose = params[:purpose].to_s
    slot = params[:slot].to_s
    allowed = if @secure_form
                case params[:secure_form_type]
                when 'proof' then { 'proof' => ["#{SecureRequestForm::PROOF_TYPES_BY_KIND.fetch(@secure_form.kind)}_proof"] }
                when 'certification' then { 'certification' => ['medical_certification'] }
                when 'w9' then { 'w9' => ['w9_form'] }
                end
              elsif @scan_user.admin?
                { 'proof' => %w[id_proof income_proof residency_proof], 'certification' => ['medical_certification'], 'product_resource' => ['document'] }
              elsif @scan_user.vendor?
                { 'w9' => ['w9_form'] }
              else
                { 'proof' => %w[id_proof income_proof residency_proof] }
              end
    raise ActiveRecord::RecordNotFound unless allowed.fetch(purpose, []).include?(slot)

    [purpose, slot]
  end

  def form_context
    value = params[:context].to_s
    raise ActiveRecord::RecordNotFound if value.length > 100

    value
  end

  def owned_scans
    scope = DocumentScan.where(created_at: DocumentScan::RETENTION.ago..)
    @secure_form ? scope.where(secure_form: @secure_form) : scope.where(user: @scan_user)
  end

  def scan_locale(&)
    I18n.with_locale(@secure_form&.delivery_locale || @scan_user&.effective_locale || I18n.default_locale, &)
  end

  def scan_json(scan)
    { id: scan.id, status: scan.status, filename: scan.blob.filename.to_s,
      status_url: document_scan_path(scan, **public_context),
      signed_id: scan.clean? && !scan.dismissed_at ? scan.blob.signed_id(expires_in: DocumentScan::RETENTION) : nil,
      message: t("documents.scan.#{scan.status}") }
  end

  def public_context
    @secure_form ? { secure_form_type: params[:secure_form_type], token: params[:token] } : {}
  end
end
