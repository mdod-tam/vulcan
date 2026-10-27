# frozen_string_literal: true

# Status badges. Each status family maps its states to a badge variant, a color group defined by .badge-*
# in application.tailwind.css:
#   neutral  not started, closed, or no information      success    done, approved, available
#   info     in progress, or an appointment is booked    warning    waiting on someone
#   attention follows up on something that went wrong    danger     failed, rejected, blocked, cancelled
#   accent   under review                                primary    brand emphasis
# Two states of one family share a variant only when they mean the same thing to the reader. Color never
# carries the state alone: every badge states it in words.
#
# Families beyond the application workflow:
#   invoice              draft and withdrawn are both neutral: neither is waiting on anyone
#   voucher              redeemed (fully used) is info; expired is danger; cancelled is neutral because it is closed
#   voucher_transaction  cancelled is neutral, so it differs from pending (warning) and failed (danger)
#   delivery             in-flight states (queued, accepted, released, submitted, DocuSeal) are info; delayed is
#                        warning; the three "Not sent" states are attention; bounced, complained, and failed are danger
module BadgeHelper
  VARIANT_MAPS = {
    document_scan: { clean: :success, pending: :info, blocked: :danger, failed: :attention },
    proof: { not_reviewed: :neutral, approved: :success, rejected: :danger },
    certification: { not_requested: :neutral, requested: :warning, received: :info, approved: :success, rejected: :danger },
    application: {
      draft: :neutral, in_progress: :accent, approved: :success, rejected: :danger, awaiting_proof: :info,
      reminder_sent: :warning, awaiting_dcf: :attention, archived: :neutral
    },
    evaluation: {
      pending: :warning, requested: :warning, in_progress: :info, scheduled: :info, confirmed: :info,
      rescheduled: :info, completed: :success, cancelled: :danger, no_show: :attention
    },
    equipment: {
      needs_catalog_product: :warning, needs_action: :warning, needs_ordering: :warning, po_sent: :info,
      ordered: :info, shipped: :success
    },
    training_session: {
      requested: :warning, scheduled: :info, confirmed: :info, rescheduled: :info, completed: :success,
      cancelled: :danger, no_show: :attention
    },
    document_signing: { not_sent: :neutral, sent: :warning, opened: :info, signed: :success, declined: :danger },
    invoice: {
      invoice_draft: :neutral, invoice_pending: :warning, invoice_approved: :info, invoice_paid: :success,
      invoice_cancelled: :neutral
    },
    voucher: { active: :success, redeemed: :info, expired: :danger, cancelled: :neutral },
    w9: { not_submitted: :neutral, pending_review: :warning, approved: :success, rejected: :danger },
    voucher_transaction: {
      transaction_pending: :warning, transaction_completed: :success, transaction_failed: :danger,
      transaction_cancelled: :neutral
    },
    delivery: {
      delivered: :success, letter_printed: :success,
      queued: :info, accepted: :info, letter_released: :info, sms_submitted: :info, docuseal: :info,
      delayed: :warning,
      suppressed: :attention, letter_blocked: :attention, letter_canceled: :attention,
      bounced: :danger, complained: :danger, failed: :danger,
      unknown: :neutral
    }
  }.freeze

  def badge_variant_for(type, status)
    VARIANT_MAPS.fetch(type.to_sym, {}).fetch(status.to_s.to_sym, :neutral)
  end

  def badge_class_for(type, status, size: nil)
    badge_classes(badge_variant_for(type, status), size: size)
  end

  def badge_classes(variant, size: nil)
    class_names('badge', "badge-#{variant}", 'badge-lg': size == :lg)
  end

  # A badge for any text and variant, for values that are not one of the status families above.
  def badge(text, variant = :neutral, size: nil, **options)
    extra_class = options.delete(:class)
    tag.span(text, **options, class: class_names(badge_classes(variant, size: size), extra_class))
  end

  # The badge for one status of a family. Page-level status badges are large by default.
  def status_badge(type, status, label: nil, size: :lg)
    badge(label || badge_label_for(type, status), badge_variant_for(type, status), size: size)
  end

  def medical_certification_label(application)
    status = application.medical_certification_status.to_s
    label = case status
            when 'requested'
              'Disability Certification Request'
            when 'received'
              'Disability Certification Received'
            when 'approved'
              'Disability Certification Approved'
            when 'not_requested', 'rejected'
              'Disability Certification'
            else
              'Unknown Certification Status'
            end
    # Append the status unless the label already contains it.
    label += " #{status}" if status != 'not_requested' && label.exclude?(status.titleize)
    label
  end

  def badge_label_for(type, status)
    if type.to_sym == :document_scan
      return { 'clean' => 'Passed', 'pending' => 'Pending', 'blocked' => 'Blocked', 'failed' => 'Failed' }.fetch(status.to_s, 'Not scanned')
    end

    # An evaluation that is still pending reads as requested.
    return 'Requested' if type.to_sym == :evaluation && status.to_s == 'pending'

    # A confirmed training session reads as scheduled.
    return 'Scheduled' if type.to_sym == :training_session && status.to_s == 'confirmed'

    status.to_s.humanize
  end
end
