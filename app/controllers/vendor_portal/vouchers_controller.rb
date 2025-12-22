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

    def verify
      # Initialize the verification attempts
      reset_verification_attempts
    end

    def verify_dob
      # Use the verification service to check the DOB
      verification_service = VoucherVerificationService.new(
        @voucher,
        params[:date_of_birth],
        session
      )

      result = verification_service.verify

      # Record verification attempt in events
      record_verification_event(result.success?)

      if result.success?
        flash[:notice] = t("alerts.#{result.message_key}")
        redirect_to redeem_vendor_portal_voucher_path(@voucher.code)
      else
        flash[:alert] = if result.attempts_left&.positive?
                          t("alerts.#{result.message_key}", attempts_left: result.attempts_left)
                        else
                          t("alerts.#{result.message_key}")
                        end

        if result.attempts_left&.zero?
          redirect_to vendor_portal_vouchers_path
        else
          redirect_to verify_vendor_portal_voucher_path(@voucher.code)
        end
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

    def reset_verification_attempts
      session[:voucher_verification_attempts] ||= {}
      session[:voucher_verification_attempts][@voucher.id.to_s] = 0
    end

    def record_verification_event(successful)
      Event.create!(
        user: current_user,
        action: 'voucher_verification_attempt',
        metadata: {
          voucher_id: @voucher.id,
          voucher_code: @voucher.code,
          constituent_id: @voucher.application.user_id,
          successful: successful,
          attempt_number: session[:voucher_verification_attempts][@voucher.id.to_s] || 0
        }
      )
    end
  end
end
