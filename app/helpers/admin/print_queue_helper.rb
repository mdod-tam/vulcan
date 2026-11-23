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
                  'Cancel this unprinted letter? Discard unused copies.'
                else
                  'Cancel this letter?'
                end
      message += ' This also closes the request.' if letter.secure_request_form&.postal_request_open?
      message
    end

    def provider_request_replacement_label(form)
      return 'Replace paper request' if form.recipient_channel_letter?

      t('admin.applications.secure_request_forms.table.resend')
    end

    def secure_request_replacement_confirmation(form, letter: nil)
      return t('admin.applications.secure_request_forms.table.resend_confirm') unless form.recipient_channel_letter?

      letter ||= form.print_queue_items.max_by(&:id)
      return 'Replace this paper request?' unless letter&.released_at? && letter.pending?

      'Replace this paper request? Mark the old letter as printed if you printed it. Discard unused copies.'
    end

    def secure_request_close_button(application, form, recipient:, proof_type: nil)
      if form.recipient_channel_letter?
        label = 'Close paper request'
        confirmation = paper_request_close_confirmation(form.print_queue_items.max_by(&:id))
      else
        table = proof_type ? 'proof_secure_request_forms' : 'secure_request_forms'
        label = t("admin.applications.#{table}.table.revoke")
        confirmation = t("admin.applications.#{table}.table.revoke_confirm", proof_type: proof_type)
      end

      button_to label, admin_application_secure_request_form_revocation_path(application, form),
                method: :post, class: 'btn btn-danger-outline btn-sm',
                form: { class: 'inline', data: { turbo_confirm: confirmation, turbo_frame: '_top' } },
                aria: { label: secure_link_row_action_label(label, form, recipient: recipient) }
    end

    private

    def paper_request_close_confirmation(letter)
      return 'Close this paper request? Its letter will be canceled if it hasn’t been downloaded.' unless letter&.released_at?
      return 'Close this paper request? Discard any unused copy.' if letter.pending?

      'Close this paper request?'
    end
  end
end
