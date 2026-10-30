# frozen_string_literal: true

module Admin
  # Issues a voucher for an approved application.
  class ApplicationVouchersController < BaseController
    include LoadsApplication

    def assign_voucher
      result = Vouchers::IssuanceService.new(@application, actor: current_user).call

      if result.success?
        redirect_to admin_application_path(@application), notice: t('admin.applications.assign_voucher.v_assign_pass')
      else
        redirect_to admin_application_path(@application), alert: t('admin.applications.assign_voucher.v_assign_fail')
      end
    end
  end
end
