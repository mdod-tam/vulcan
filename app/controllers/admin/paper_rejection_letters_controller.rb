# frozen_string_literal: true

module Admin
  class PaperRejectionLettersController < BaseController
    before_action :load_receipt

    def show
      @letter = PrintQueueItem.find_by("delivery_context->>'notification_id' = ?", @receipt.id.to_s)
      @reason = @receipt.metadata.dig('delivery_error', 'reason') || @receipt.metadata.dig('delivery_suppressed', 'reason')
    end

    def record_manual_mail
      @receipt.with_lock do
        if @receipt.error_delivery_status? && @receipt.metadata.dig('delivery_error', 'reason') == 'unsupported_letter_text' &&
           @receipt.metadata['mailed_manually_at'].blank?
          @receipt.update_metadata!(:mailed_manually_at, Time.current.iso8601)
          AuditEventService.log(action: 'paper_rejection_mailed_manually', actor: current_user, auditable: @receipt)
        end
      end

      redirect_to admin_paper_rejection_letter_path(@receipt), status: :see_other
    end

    private

    def load_receipt
      @receipt = Notification.paper_rejection_letters.find(params.expect(:id))
    end
  end
end
