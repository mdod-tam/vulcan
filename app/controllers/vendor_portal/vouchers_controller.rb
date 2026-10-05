# frozen_string_literal: true

module VendorPortal
  # Controller for managing vouchers
  class VouchersController < BaseController
    include ActionView::Helpers::NumberHelper # For number_to_currency

    before_action :set_voucher, only: %i[show verify verify_dob redeem process_redemption]
    before_action :check_voucher_active, only: %i[verify redeem]
    before_action :check_identity_verified, only: %i[redeem]

    def index
      @vouchers = current_user.processed_vouchers.order(updated_at: :desc)

      return if params[:code].blank?

      voucher = Voucher.where(status: :active).find_by(code: params[:code])
      if voucher
        redirect_to verify_vendor_portal_voucher_path(voucher.code)
      else
        flash.now[:alert] = t('alerts.invalid_voucher_code', default: 'Invalid voucher code')
      end
    end

    def show
      # @voucher is set by before_action :set_voucher
      # Show voucher details for vendor
    end

    # Viewing the form never resets the failure count; only a successful check or the lockout
    # period does.
    def verify
      retry_at = VoucherVerificationThrottle.locked_until_for(@voucher, current_user)
      return unless retry_at

      redirect_to vendor_portal_vouchers_path, alert: locked_out_message(retry_at)
    end

    def verify_dob
      result = VoucherVerificationService.new(@voucher, params[:date_of_birth], session, vendor: current_user).verify

      record_verification_event(result)

      if result.success?
        flash[:notice] = t("alerts.#{result.message_key}")
        redirect_to redeem_vendor_portal_voucher_path(@voucher.code)
      elsif result.locked_out?
        redirect_to vendor_portal_vouchers_path, alert: locked_out_message(result.retry_at)
      else
        flash[:alert] = t("alerts.#{result.message_key}", attempts_left: result.attempts_left)
        redirect_to verify_vendor_portal_voucher_path(@voucher.code)
      end
    end

    def redeem
      # check_voucher_active and check_identity_verified before actions
      # will redirect if necessary
      @products = Product.order(:name)
    end

    def process_redemption
      # Delegate to service for all business logic
      result = Vouchers::RedemptionService.call(
        voucher: @voucher,
        vendor: current_user,
        amount: params[:amount],
        product_ids: params[:product_ids],
        notes: params[:notes],
        session: session
      )

      if result.success?
        flash[:notice] = result.message
        redirect_to vendor_portal_dashboard_path
      else
        flash[:alert] = result.message
        # Redirect to verify page if identity verification is required, otherwise back to redeem form
        redirect_path = if result.data&.dig(:error_type) == :identity_verification_required
                          verify_vendor_portal_voucher_path(@voucher.code)
                        else
                          redeem_vendor_portal_voucher_path(@voucher.code)
                        end
        redirect_to redirect_path
      end
    end

    private

    def set_voucher
      # Voucher lookup gracefully handles invalid codes by redirecting with error message
      # This prevents RecordNotFound exceptions from bubbling up to the UI
      @voucher = Voucher.find_by(code: params[:code])
      return if @voucher

      flash[:alert] = 'Invalid voucher code'
      redirect_to vendor_portal_vouchers_path
    end

    def check_voucher_active
      return if @voucher.voucher_active?

      flash[:alert] = 'This voucher is not active or has already been processed'
      redirect_to vendor_portal_vouchers_path
    end

    def check_identity_verified
      return if identity_verified?(@voucher)

      flash[:alert] = 'Identity verification is required before redemption'
      redirect_to verify_vendor_portal_voucher_path(@voucher.code)
    end

    def identity_verified?(voucher)
      session[:verified_vouchers].present? &&
        session[:verified_vouchers].include?(voucher.id)
    end

    def locked_out_message(retry_at)
      t('alerts.dob_verification_too_many_attempts', retry_at: retry_at.in_time_zone.strftime('%-I:%M %p'))
    end

    def record_verification_event(result)
      AuditEventService.log(
        actor: current_user,
        action: 'voucher_verification_attempt',
        auditable: @voucher,
        metadata: {
          voucher_id: @voucher.id,
          voucher_code: @voucher.code,
          constituent_id: @voucher.application.user_id,
          successful: result.success?,
          locked_out: result.locked_out?,
          attempt_number: result.attempt_number,
          # Each request is its own attempt; without this, rapid guesses fall inside the audit
          # dedup window and go unrecorded.
          operation_id: "voucher_verification:#{request.request_id}"
        }
      )
    end
  end
end
