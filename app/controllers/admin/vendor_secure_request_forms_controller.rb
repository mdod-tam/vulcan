# frozen_string_literal: true

module Admin
  class VendorSecureRequestFormsController < BaseController
    before_action :set_vendor

    def create
      result = Vendors::RequestW9Resubmission.new(
        vendor: @vendor,
        actor: current_user,
        resend_of: resend_vendor_secure_request_form
      ).call

      if result.success?
        redirect_to admin_vendor_path(@vendor),
                    notice: t('admin.vendors.vendor_secure_request_forms.create.success')
      else
        redirect_to admin_vendor_path(@vendor),
                    alert: result.message.presence || t('admin.vendors.vendor_secure_request_forms.create.failure')
      end
    end

    private

    def set_vendor
      @vendor = Users::Vendor.find(params[:vendor_id])
    end

    def resend_vendor_secure_request_form
      return if params[:resend_of_id].blank?

      @resend_vendor_secure_request_form ||= @vendor.vendor_secure_request_forms.find(params[:resend_of_id])
    end
  end
end
