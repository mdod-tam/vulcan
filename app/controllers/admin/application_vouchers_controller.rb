# frozen_string_literal: true

module Admin
  # Issues a voucher for an approved application.
  class ApplicationVouchersController < BaseController
    include LoadsApplication

    def assign_voucher
      result = Vouchers::IssuanceService.new(@application, actor: current_user).call

      if result.success?
        warning = result.message if result.data&.dig(:warning)
        redirect_to admin_application_path(@application), notice: t('admin.applications.assign_voucher.v_assign_pass'), alert: warning
      else
        redirect_to admin_application_path(@application), alert: result.message.presence || t('admin.applications.assign_voucher.v_assign_fail')
      end
    end
  end
end
