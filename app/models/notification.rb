# frozen_string_literal: true

class Notification < ApplicationRecord
  attr_accessor :delivery_successful

  # Suffix: true generates methods like `delivered_status?` and scopes like `delivered_status`.
  # queued and submitted mean the provider has the message, not that the recipient received it;
  # suppressed means it was intentionally not sent.
  enum :delivery_status, {
    queued: 'queued', submitted: 'submitted', delivered: 'delivered', opened: 'opened', error: 'error',
    suppressed: 'suppressed'
  }, suffix: true

  belongs_to :recipient, class_name: 'User'
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :notifiable, polymorphic: true, optional: true

  validates :action, presence: true

  scope :unread_notifications, -> { where(read_at: nil) }
  scope :read_notifications, -> { where.not(read_at: nil) }
  scope :medical_certification_requests, -> { where(action: 'medical_certification_requested') }

  def self.proof_resubmission_rejected_metadata?(metadata)
    mode = metadata_value(metadata, 'proof_request_display_mode') || metadata_value(metadata, 'display_mode')

    mode.to_s == 'rejected'
  end

  def mark_as_read!
    update!(read_at: Time.current)
  end

  # Email status methods for medical certification requests.
  # These methods depend on the `message_id` column in the `notifications` table
  # and the existence of an `UpdateEmailStatusJob`.
  def email_tracking?
    message_id.present?
  end

  # An outcome recorded here without the provider: suppressed, or failed before handoff.
  # It is shown even when there is no provider message id to poll.
  def local_delivery_outcome?
    suppressed_delivery_status? || error_delivery_status?
  end

  def check_email_status!
    return unless email_tracking?

    UpdateEmailStatusJob.perform_later(id)
  end

  def email_error_message
    return nil unless delivery_status == 'error'
    return 'Unknown error' unless metadata.is_a?(Hash)

    metadata.fetch('delivery_error', {}).fetch('message', 'Unknown error')
  end

  def record_delivery_handoff!(channel:, state: :submitted)
    with_lock do
      next if local_delivery_outcome?

      update!(delivery_status: state,
              metadata: metadata.to_h.merge('actual_delivery_channel' => channel.to_s,
                                            'delivery_route_reason' => channel.to_s == 'letter' ? 'queued_for_printing' : 'provider_submission'))
    end
  end

  # Records that this notification's email was intentionally not sent.
  def mark_delivery_suppressed!(reason, channel: :email)
    mark_delivery_not_sent!(EmailDelivery::Decision.suppressed(reason), channel: channel)
  end

  # Both policy outcomes use the same locked write as routing, preserving unrelated metadata.
  def mark_delivery_not_sent!(decision, channel: :email)
    raise ArgumentError, 'Expected a delivery refusal' if decision.allowed?

    details = { 'reason' => decision.reason }
    if decision.configuration_error?
      details['message'] = EmailDelivery::ConfigurationError::MESSAGE
      key = 'delivery_error'
      status = :error
      route = "#{channel}_configuration_error"
    else
      key = 'delivery_suppressed'
      status = :suppressed
      route = "#{channel}_suppressed"
    end

    with_lock do
      update!(delivery_status: status,
              metadata: metadata.to_h.except('delivery_suppressed', 'delivery_error').merge(
                key => details, 'actual_delivery_channel' => 'none', 'delivery_route_reason' => route
              ))
    end
  end

  def update_metadata!(key, value)
    with_lock do
      new_metadata = metadata || {}
      new_metadata[key.to_s] = value
      update!(metadata: new_metadata)
    end
  end

  # The adapter can fail after the caller commits and finishes recording its intended route.
  def mark_delivery_enqueue_failed!(error)
    with_lock do
      unless local_delivery_outcome?
        update!(delivery_status: :error, metadata: metadata.to_h.merge(
          'actual_delivery_channel' => 'none', 'delivery_route_reason' => 'email_enqueue_failed',
          'delivery_error' => { 'message' => 'Email could not be queued.', 'error_class' => error.class.name }
        ))
      end
    end
  end

  # Generate a human-readable message for the notification by delegating to the NotificationComposer.
  # This ensures all message logic is centralized and consistent.
  def message(viewer = nil)
    NotificationComposer.generate(action, notifiable, actor, metadata, viewer: viewer)
  end

  def proof_resubmission_rejected?
    action == 'proof_resubmission_requested' && self.class.proof_resubmission_rejected_metadata?(metadata)
  end

  def self.metadata_value(metadata, key)
    return unless metadata.respond_to?(:[])

    metadata[key.to_s] || metadata[key.to_sym]
  end
  private_class_method :metadata_value
end
