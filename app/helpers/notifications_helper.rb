# frozen_string_literal: true

module NotificationsHelper
  REJECTED_NOTIFICATION_ACTIONS = %w[
    proof_rejected
    id_proof_rejected
    income_proof_rejected
    residency_proof_rejected
    medical_certification_rejected
  ].freeze

  def notification_icon_classes(notification)
    return 'bg-red-100 text-red-500' if REJECTED_NOTIFICATION_ACTIONS.include?(notification.action)

    if notification.action == 'proof_resubmission_requested'
      proof_resubmission_rejected_notification?(notification) ? 'bg-red-100 text-red-500' : 'bg-yellow-100 text-yellow-500'
    elsif %w[trainer_assigned proof_approved medical_certification_approved].include?(notification.action)
      'bg-green-100 text-green-500'
    elsif %w[training_requested medical_certification_requested medical_certification_received].include?(notification.action)
      'bg-blue-100 text-blue-500'
    elsif notification.action == 'documents_requested'
      'bg-yellow-100 text-yellow-500'
    elsif notification.action == 'review_requested'
      'bg-purple-100 text-purple-500'
    else
      'bg-indigo-100 text-indigo-500'
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
    return 'bg-gray-100 text-gray-600' unless notification.email_tracking?

    case notification.delivery_status
    when 'delivered' then 'bg-green-100 text-green-800'
    when 'opened'    then 'bg-blue-100 text-blue-800'
    when 'error'     then 'bg-red-100 text-red-800'
    else 'bg-yellow-100 text-yellow-800'
    end
  end

  def proof_resubmission_rejected_notification?(notification)
    notification.proof_resubmission_rejected?
  end
end
