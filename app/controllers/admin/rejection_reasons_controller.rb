# frozen_string_literal: true

module Admin
  class RejectionReasonsController < Admin::BaseController
    before_action :set_rejection_reason, only: %i[edit update mark_synced]
    before_action :load_locale_reasons, only: %i[edit update]

    def index
      reasons = RejectionReason.order(:proof_type, :code, :locale)
      @reason_groups = reasons.group_by { |reason| [reason.proof_type, reason.code] }.map do |(proof_type, code), records|
        {
          proof_type: proof_type,
          code: code,
          en: records.find { |reason| reason.locale == 'en' },
          es: records.find { |reason| reason.locale == 'es' }
        }
      end
    end

    def edit; end

    def update
      target_reason = reason_for_locale(params[:locale].presence || @rejection_reason.locale)
      target_locale = target_reason&.locale&.upcase || params[:locale].to_s.upcase

      unless target_reason
        redirect_to edit_admin_rejection_reason_path(@rejection_reason),
                    alert: "Could not find #{target_locale} rejection reason for this pair."
        return
      end

      if target_reason.update(rejection_reason_params.merge(updated_by: current_user))
        @rejection_reason = target_reason
        redirect_to edit_admin_rejection_reason_path(target_reason),
                    notice: "#{target_locale} rejection reason updated."
      else
        if target_reason.locale == 'en'
          @en_reason = target_reason
        else
          @es_reason = target_reason
        end

        flash.now[:alert] = "Failed to update #{target_locale} rejection reason: #{target_reason.errors.full_messages.join(', ')}"
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
      @rejection_reason = RejectionReason.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_rejection_reasons_path, alert: 'Rejection reason not found.'
    end

    def load_locale_reasons
      reasons_by_locale = RejectionReason.includes([:updated_by]).where(code: @rejection_reason.code, proof_type: @rejection_reason.proof_type, locale: %w[en es])
                                         .index_by(&:locale)
      @en_reason = reasons_by_locale['en']
      @es_reason = reasons_by_locale['es']
    end

    def rejection_reason_params
      params.expect(rejection_reason: [:body])
    end

    def reason_for_locale(locale)
      locale.to_s == 'es' ? @es_reason : @en_reason
    end

    def counterpart_locale(locale)
      locale.to_s == 'en' ? 'es' : 'en'
    end
  end
end
