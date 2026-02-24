# frozen_string_literal: true

module Admin
  class RejectionReasonsController < Admin::BaseController
    before_action :set_rejection_reason, only: %i[edit update mark_synced]

    def index
      reasons = RejectionReason.includes(:updated_by).order(:proof_type, :code, :locale)
      @reason_groups = reasons.group_by { |reason| [reason.proof_type, reason.code] }.map do |(proof_type, code), records|
        {
          proof_type: proof_type,
          code: code,
          en: records.find { |reason| reason.locale == 'en' },
          es: records.find { |reason| reason.locale == 'es' }
        }
      end
    end

    def edit
      @counterpart_reason = counterpart_reason
    end

    def update
      if @rejection_reason.update(rejection_reason_params.merge(updated_by: current_user))
        redirect_to edit_admin_rejection_reason_path(@rejection_reason),
                    notice: "#{@rejection_reason.locale.to_s.upcase} rejection reason updated."
      else
        @counterpart_reason = counterpart_reason
        flash.now[:alert] = "Failed to update rejection reason: #{@rejection_reason.errors.full_messages.join(', ')}"
        render :edit, status: :unprocessable_content
      end
    end

    def mark_synced
      @rejection_reason.update_column(:needs_sync, false) # rubocop:disable Rails/SkipsModelValidations
      redirect_to edit_admin_rejection_reason_path(@rejection_reason),
                  notice: 'Rejection reason marked as synced.'
    end

    private

    def set_rejection_reason
      @rejection_reason = RejectionReason.includes(:updated_by).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_rejection_reasons_path, alert: 'Rejection reason not found.'
    end

    def rejection_reason_params
      params.expect(rejection_reason: [:body])
    end

    def counterpart_reason
      RejectionReason.includes(:updated_by).find_by(
        code: @rejection_reason.code,
        proof_type: @rejection_reason.proof_type,
        locale: counterpart_locale(@rejection_reason.locale)
      )
    end

    def counterpart_locale(locale)
      locale.to_s == 'en' ? 'es' : 'en'
    end
  end
end
