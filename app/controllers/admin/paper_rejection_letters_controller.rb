# frozen_string_literal: true

module Admin
  class PaperRejectionLettersController < BaseController
    before_action :load_receipt
    helper_method :manual_mail_available?, :manual_mail_recorded?

    def show
      @letter = PrintQueueItem.find_by("delivery_context->>'notification_id' = ?", @receipt.id.to_s)
      outcome_key = @receipt.error_delivery_status? ? 'delivery_error' : 'delivery_suppressed'
      outcome = @receipt.metadata.fetch(outcome_key, {})
      return unless (reason = outcome['reason'])

      @reason_text = EmailDelivery::ControlPanel.reason_text(
        reason, category: :application, unsupported_codepoint: outcome['unsupported_codepoint']
      ).upcase_first
    end

    def record_manual_mail
      feedback = @receipt.with_lock do
        if manual_mail_available?
          @receipt.update_metadata!(:mailed_manually_at, Time.current.iso8601)
          AuditEventService.log(action: 'paper_rejection_mailed_manually', actor: current_user, auditable: @receipt)
          {}
        elsif manual_mail_recorded?
          { notice: 'Manual mailing is already recorded.' }
        else
          { alert: 'Manual mailing is unavailable for this letter.' }
        end
      end

      redirect_to admin_paper_rejection_letter_path(@receipt), status: :see_other, **feedback
    end

    private

    def manual_mail_available?
      @receipt.error_delivery_status? && @receipt.metadata.dig('delivery_error', 'reason') == 'unsupported_letter_text' && !manual_mail_recorded?
    end

    def manual_mail_recorded?
      @receipt.metadata['mailed_manually_at'].present?
    end

    def load_receipt
      @receipt = Notification.paper_rejection_letters.find(params.expect(:id))
    end
  end
end
