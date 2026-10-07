# frozen_string_literal: true

module VendorPortal
  # Base controller for all vendor portal controllers
  class BaseController < ApplicationController
    before_action :authenticate_vendor!
    layout 'vendor_portal'

    private

    # Users::Vendor#can_process_vouchers? is the one eligibility rule. Every path that checks a date
    # of birth or looks up a voucher code runs this first, so an unapproved vendor learns nothing
    # about a voucher or its constituent.
    def require_voucher_processing_approval
      return if current_user.can_process_vouchers?

      # For operators watching for probing. Never the submitted code: it may be someone's voucher.
      Rails.logger.warn("VendorPortal: refused #{controller_name}##{action_name} for vendor #{current_user.id}: " \
                        'not approved to process vouchers')
      message = t('alerts.vendor_not_approved_for_vouchers')
      redirect_to vendor_portal_dashboard_path, alert: message
    end

    def authenticate_vendor!
      # First ensure user is authenticated
      authenticate_user!

      # Then verify they are a vendor
      return if current_user&.vendor?

      # Handle format-specific responses for authentication failures
      respond_to do |format|
        format.html do
          flash[:alert] = I18n.t('alerts.must_be_vendor', default: 'You must be a vendor to access this section')
          redirect_to root_path
        end

        format.json do
          render json: { error: 'Unauthorized. Vendor access required.' }, status: :unauthorized
        end

        format.any do
          head :unauthorized
        end
      end
    end
  end
end
