# frozen_string_literal: true

module Admin
  module PrintQueueHelper
    # The three proof-rejection letters share one variant, and the two approval letters share another.
    LETTER_TYPE_VARIANTS = {
      'account_created' => :info,
      'registration_confirmation' => :accent,
      'income_proof_rejected' => :attention,
      'residency_proof_rejected' => :attention,
      'id_proof_rejected' => :attention,
      'income_threshold_exceeded' => :danger,
      'proof_approved' => :success
    }.freeze

    def letter_type_badge_class(letter_type)
      badge_classes(LETTER_TYPE_VARIANTS.fetch(letter_type.to_s, :neutral))
    end

    def print_letter_type_label(letter)
      if letter.other_notification? && (proof_type = SecureRequestForm::PROOF_TYPES_BY_KIND[letter.secure_request_form&.kind])
        return "#{ProofNotificationCopy.proof_label(proof_type, locale: :en)} request"
      end

      letter.letter_type.humanize
    end

    def print_letter_stage(letter)
      return 'Resolve downloaded copy' if letter.downloaded_copy_to_resolve?

      {
        queued: 'Awaiting release', blocked: 'Blocked', configuration_error: 'Needs attention',
        released: 'Awaiting print confirmation', printed: 'Printed', canceled: 'Canceled'
      }.fetch(letter.display_delivery_state)
    end

    def rejection_letter_status(letter)
      return print_letter_stage(letter) unless letter.display_delivery_state == :queued

      letter.pdf_letter.attached? ? 'Ready to print' : 'PDF missing'
    end

    def letter_delivery_reason(letter, reason)
      EmailDelivery::ControlPanel.reason_text(reason, category: letter.delivery_context&.dig('category')).upcase_first
    end

    def print_letter_cancel_confirmation(letter)
      return 'Discard the unused copy and cancel this letter?' if letter.downloaded_copy_to_resolve?

      message = if letter.released_at?
                  'Cancel this unprinted letter? Discard unused copies. Downloaded PDFs cannot be recalled.'
                else
                  'Cancel this letter before printing?'
                end
      message += ' This also closes the linked request.' if letter.secure_request_form&.postal_request_open?
      message
    end

    def provider_request_replacement_label(form)
      return 'Replace paper request' if form.recipient_channel_letter?

      t('admin.applications.secure_request_forms.table.resend')
    end

    def secure_request_replacement_confirmation(form)
      return 'Replace this paper request? Confirm printing first if a copy was printed. Discard unused downloads.' if form.recipient_channel_letter?

      t('admin.applications.secure_request_forms.table.resend_confirm')
    end
  end
end
