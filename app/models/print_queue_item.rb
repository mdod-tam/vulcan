# frozen_string_literal: true

# == Schema Information
#
# Table name: print_queue_items
#
#  id              :bigint           not null, primary key
#  letter_type     :integer          not null
#  status          :integer          default("pending"), not null
#  constituent_id  :bigint           not null
#  application_id  :bigint
#  admin_id        :bigint
#  printed_at      :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class PrintQueueItem < ApplicationRecord
  belongs_to :constituent, class_name: 'User'
  belongs_to :application, optional: true
  belongs_to :secure_request_form, optional: true
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, optional: true, class_name: 'User'

  has_one_attached :pdf_letter

  # Define enums with explicit name parameter
  enum :letter_type, {
    account_created: 0,
    income_proof_rejected: 1,
    residency_proof_rejected: 2,
    income_threshold_exceeded: 3,
    application_approved: 4,
    registration_confirmation: 5,
    other_notification: 6,
    proof_approved: 7,
    max_rejections_reached: 8,
    proof_submission_error: 9,
    evaluation_submitted: 10,
    medical_certification_form: 11,
    provider_info_requested: 12,
    id_proof_rejected: 13
  }

  enum :status, { pending: 0, printed: 1, canceled: 2 }

  validates :letter_type, presence: true
  validates :pdf_letter, presence: true, on: :create

  scope :pending, -> { where(status: :pending) }
  scope :recent, -> { order(created_at: :desc) }
  scope :unreleased, -> { pending.where(released_at: nil) }
  scope :awaiting_print_confirmation, -> { pending.where.not(released_at: nil) }

  attr_accessor :delivery_write

  validate :delivery_changes_use_owner, on: :update

  def self.identity_for(recipient:, application: nil, secure_request_form: nil)
    fields = recipient.attributes.slice('first_name', 'last_name', 'physical_address_1', 'physical_address_2',
                                        'city', 'state', 'zip_code', 'locale', 'status', 'merged_into_user_id')
    { 'recipient_id' => recipient.id, 'recipient_digest' => Digest::SHA256.hexdigest(fields.sort.to_json),
      'application_user_id' => application&.user_id, 'managing_guardian_id' => application&.managing_guardian_id,
      'request_recipient_id' => secure_request_form&.recipient_id,
      'delivery_owner_id' => secure_request_form&.delivery_owner_id }.compact
  end

  def display_delivery_state
    return :printed if printed?
    return :released if released_at
    return :canceled if canceled?

    decision = delivery_decision
    return :configuration_error if decision.configuration_error?

    decision.allowed? ? :queued : :canceled
  end

  def delivery_decision
    return EmailDelivery::Decision.suppressed(cancellation_reason || :pending_canceled) if canceled?

    decision = EmailDelivery::Policy.verify(delivery_context, channel: :letter)
    return decision unless decision.allowed?

    current_identity = self.class.identity_for(recipient: constituent, application: application, secure_request_form: secure_request_form)
    return EmailDelivery::Decision.suppressed(:delivery_identity_changed) unless delivery_identity == current_identity
    if released_at.nil? && secure_request_form && !SecureRequestForm.active.exists?(id: secure_request_form_id)
      return EmailDelivery::Decision.suppressed(:request_no_longer_active)
    end

    EmailDelivery::Decision.allowed
  end

  # Called with the item locked by Letters::Delivery. Release is authorization, not proof of printing.
  def release_for_printing!(actor:)
    return if released_at

    self.delivery_write = true
    update!(released_at: Time.current)
    record_delivery_event('letter_released_for_printing', actor: actor)
  end

  def cancel_unreleased!(reason:, actor:)
    return false unless pending? && released_at.nil?

    self.delivery_write = true
    update!(status: :canceled, canceled_at: Time.current, cancellation_reason: reason)
    secure_request_form&.revoke!(actor: actor, reason: :delivery_suppressed, metadata: { suppression_reason: reason })
    record_delivery_event('letter_delivery_canceled', actor: actor, reason: reason)
    true
  end

  def confirm_printed!(actor:)
    raise Letters::Delivery::ReleaseDenied, { id => 'Release this letter before marking it printed.' } unless released_at && !canceled?
    return if printed?

    self.delivery_write = true
    update!(status: :printed, printed_at: Time.current, admin: actor)
    record_delivery_event('letter_printed', actor: actor)
  end

  def mark_as_printed(admin)
    Letters::Delivery.mark_printed!([id], actor: admin)
  end

  def pdf_filename
    "#{letter_type}_#{id || 'new'}.pdf"
  end

  private

  def record_delivery_event(action, actor:, **metadata)
    actor ||= PublicAuditActor.system_audit_actor_or_report(action)
    return unless actor

    AuditEventService.log(action: action, actor: actor, auditable: self,
                          metadata: metadata.merge(operation_id: "#{action}:#{id}", print_queue_item_id: id))
  end

  def delivery_changes_use_owner
    return if delivery_write || delivery_context.blank?
    return unless changes.keys.intersect?(%w[status constituent_id delivery_context delivery_identity delivery_key released_at canceled_at])

    errors.add(:base, 'Letter delivery changes must use Letters::Delivery')
  end
end
