# frozen_string_literal: true

module NotificationsHelper
  REJECTED_NOTIFICATION_ACTIONS = %w[
    proof_rejected
    id_proof_rejected
    income_proof_rejected
    residency_proof_rejected
    medical_certification_rejected
  ].freeze

  # Icon colors: danger for rejections, success for approvals, info for requests in progress, warning for
  # missing documents, purple for review requests, and the brand color for everything else.
  def notification_icon_classes(notification)
    return 'bg-danger-100 text-danger-700' if REJECTED_NOTIFICATION_ACTIONS.include?(notification.action)

    if notification.action == 'proof_resubmission_requested'
      proof_resubmission_rejected_notification?(notification) ? 'bg-danger-100 text-danger-700' : 'bg-warning-100 text-warning-700'
    elsif %w[trainer_assigned proof_approved medical_certification_approved].include?(notification.action)
      'bg-success-100 text-success-700'
    elsif %w[training_requested medical_certification_requested medical_certification_received].include?(notification.action)
      'bg-info-100 text-info-700'
    elsif notification.action == 'documents_requested'
      'bg-warning-100 text-warning-700'
    elsif notification.action == 'review_requested'
      'bg-purple-100 text-purple-700'
    else
      'bg-primary-100 text-primary-700'
    end
  end

  def notification_icon_type(notification)
    case notification.action
    when 'training_requested'
      :training_requested
    when 'trainer_assigned'
      :trainer_assigned
    when 'medical_certification_requested', 'medical_certification_received'
      :medical
    when 'proof_approved', 'medical_certification_approved'
      :approved
    when *REJECTED_NOTIFICATION_ACTIONS
      :rejected
    when 'proof_resubmission_requested'
      proof_resubmission_rejected_notification?(notification) ? :rejected : :documents
    when 'documents_requested'
      :documents
    else
      :default
    end
  end

  def delivery_status_badge_class(notification)
    DeliveryStatusPresenter.new(notification, attempt: notification.email_delivery_attempts.max_by(&:id)).badge_class
  end

  def proof_resubmission_rejected_notification?(notification)
    notification.proof_resubmission_rejected?
  end
end
