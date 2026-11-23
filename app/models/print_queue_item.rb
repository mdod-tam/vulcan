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
  belongs_to :mail_handoff_by, class_name: 'User', optional: true

  has_one_attached :pdf_letter

  enum :letter_type, {
    account_created: 0,
    income_proof_rejected: 1,
    residency_proof_rejected: 2,
    income_threshold_exceeded: 3,
    registration_confirmation: 5,
    other_notification: 6,
    proof_approved: 7,
    max_rejections_reached: 8,
    proof_submission_error: 9,
    evaluation_submitted: 10,
    disability_certification_form: 11,
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
  scope :awaiting_mail_handoff, lambda {
    printed.where.not(letter_type: :disability_certification_form).where.not(released_at: nil).where(mail_handoff_at: nil, mail_discarded_at: nil)
  }
  scope :follow_up_needed, -> { canceled.where(cancellation_reason: %w[delivery_identity_changed letter_recipient_ineligible], follow_up_closed_at: nil) }
  scope :outstanding, -> { pending.or(awaiting_mail_handoff) }

  attr_accessor :delivery_write, :preloaded_delivery_state

  validate :delivery_changes_use_owner, on: :update

  RECIPIENT_IDENTITY_FIELDS = %w[first_name last_name physical_address_1 physical_address_2 city state zip_code
                                 locale status merged_into_user_id].freeze
  APPLICATION_IDENTITY_FIELDS = %w[user_id managing_guardian_id].freeze

  def self.identity_for(recipient:, application: nil, secure_request_form: nil)
    fields = recipient.attributes.slice(*RECIPIENT_IDENTITY_FIELDS)
    { 'recipient_id' => recipient.id, 'recipient_digest' => Digest::SHA256.hexdigest(fields.sort.to_json),
      'application_user_id' => application&.user_id, 'managing_guardian_id' => application&.managing_guardian_id,
      'request_recipient_id' => secure_request_form&.recipient_id,
      'delivery_owner_id' => secure_request_form&.delivery_owner_id }.compact
  end

  def display_delivery_state
    return preloaded_delivery_state if preloaded_delivery_state
    return :printed if printed?
    return :canceled if canceled?
    return :released if released_at

    decision = delivery_decision
    return :configuration_error if decision.configuration_error?

    decision.allowed? ? :queued : :blocked
  end

  def downloaded_copy_to_resolve?
    pending? && released_at? && secure_request_form.present? && !secure_request_form.postal_request_open?
  end

  def outgoing_letter?
    !disability_certification_form?
  end

  def awaiting_mail_handoff?
    outgoing_letter? && printed? && released_at? && mail_handoff_at.nil? && mail_discarded_at.nil?
  end

  def delivery_decision
    return EmailDelivery::Decision.suppressed(cancellation_reason || :pending_canceled) if canceled?
    return EmailDelivery::Decision.suppressed(:operator_canceled) if mail_discarded_at?

    decision = EmailDelivery::Policy.verify(delivery_context, channel: :letter)
    return decision unless decision.allowed?

    current_identity = self.class.identity_for(recipient: constituent, application: application, secure_request_form: secure_request_form)
    return EmailDelivery::Decision.suppressed(:delivery_identity_changed) unless delivery_identity == current_identity

    if secure_request_form && !secure_request_form.postal_recipient_authorized?(application: application, address_owner_id: constituent_id)
      return EmailDelivery::Decision.suppressed(:letter_recipient_ineligible)
    end

    if (pending? || awaiting_mail_handoff?) && secure_request_form && !secure_request_form.postal_delivery_eligible?(application: application)
      return EmailDelivery::Decision.suppressed(:request_no_longer_active)
    end

    EmailDelivery::Decision.allowed
  end

  # Letters::Delivery locks the item before this call. Release authorizes printing but does not confirm it.
  def release_for_printing!(actor:)
    return if released_at

    self.delivery_write = true
    update!(released_at: Time.current)
    record_delivery_event('letter_released_for_printing', actor: actor)
  end

  def cancel_pending!(reason:, actor:)
    return false unless pending?

    self.delivery_write = true
    update!(status: :canceled, canceled_at: Time.current, cancellation_reason: reason)
    secure_request_form&.revoke!(actor: actor, reason: :delivery_suppressed, metadata: { suppression_reason: reason })
    record_delivery_event('letter_delivery_canceled', actor: actor, reason: reason)
    true
  end

  def confirm_printed!(actor:)
    raise Letters::Delivery::ReleaseDenied, { id => 'This letter was canceled.' } if canceled?
    raise Letters::Delivery::ReleaseDenied, { id => 'Release this letter before marking it printed.' } unless released_at
    return if printed?

    self.delivery_write = true
    update!(status: :printed, printed_at: Time.current, admin: actor)
    record_delivery_event('letter_printed', actor: actor)
  end

  def confirm_mail_handoff!(actor:)
    return if mail_handoff_at?

    confirm_printed!(actor: actor)
    self.delivery_write = true
    update!(mail_handoff_at: Time.current, mail_handoff_by: actor)
    record_delivery_event('letter_in_outgoing_mail', actor: actor)
  end

  def discard_printed_copy!(actor:)
    return if mail_discarded_at?
    raise Letters::Delivery::ReleaseDenied, { id => 'This letter is no longer waiting for mail.' } unless awaiting_mail_handoff?

    self.delivery_write = true
    update!(mail_discarded_at: Time.current)
    record_delivery_event('letter_printed_copy_discarded', actor: actor)
  end

  def close_follow_up!(actor:)
    return if follow_up_closed_at?

    self.delivery_write = true
    update!(follow_up_closed_at: Time.current)
    record_delivery_event('letter_follow_up_closed', actor: actor)
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

    fields = %w[
      status constituent_id delivery_context delivery_identity delivery_key released_at canceled_at
      mail_handoff_at mail_handoff_by_id mail_discarded_at follow_up_closed_at
    ]
    return unless changes.keys.intersect?(fields)

    errors.add(:base, 'Letter delivery changes must use Letters::Delivery')
  end
end
