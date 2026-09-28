# frozen_string_literal: true

module Admin
  class VendorSecureRequestFormRevocationsController < BaseController
    before_action :set_vendor
    before_action :set_form

    def create
      # revoke! returns false when a submission committed first.
      unless @form.active? && @form.revoke!(actor: current_user, reason: :manual_revocation)
        redirect_to admin_vendor_path(@vendor),
                    alert: t('admin.vendors.vendor_secure_request_form_revocations.create.not_active')
        return
      end

      redirect_to admin_vendor_path(@vendor),
                  notice: t('admin.vendors.vendor_secure_request_form_revocations.create.success')
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid
      redirect_to admin_vendor_path(@vendor),
                  alert: t('admin.vendors.vendor_secure_request_form_revocations.create.failure')
    end

    private

    def set_vendor
      @vendor = Users::Vendor.find(params[:vendor_id])
    end

    def set_form
      @form = @vendor.vendor_secure_request_forms.find(params[:vendor_secure_request_form_id])
    end
  end
end
