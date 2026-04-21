# frozen_string_literal: true

class Evaluation < ApplicationRecord
  include StatusManagement
  include NotificationDelivery

  belongs_to :evaluator, class_name: 'User'
  belongs_to :constituent, class_name: 'Users::Constituent'
  belongs_to :application
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_and_belongs_to_many :recommended_products, class_name: 'Product', join_table: 'evaluations_products'

  enum :evaluation_type, { initial: 0, renewal: 1, special: 2 }

  # Simplified validations
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :evaluator_must_be_assignable
  validate :scheduled_time_must_be_future, on: :create

  # Conditional validations for completed status
  validates :evaluation_date,
            :location,
            :recommended_products,
            :notes,
            presence: true,
            if: :status_completed?

  validate :validate_products_tried_presence, if: :status_completed?
  validate :validate_attendees_structure, if: :status_completed?
  validate :validate_products_tried_structure, if: :status_completed?
  validate :cannot_complete_without_notes, if: :will_save_change_to_status?

  # Callbacks
  before_save :set_completed_at, if: :status_changed_to_completed?
  before_save :ensure_status_schedule_consistency
  after_save :update_application_record, if: :saved_change_to_status?
  after_save :deliver_notifications, if: :should_deliver_notifications?

  # Virtual attributes for UI
  def attendees_field
    return '' if attendees.blank?

    attendees.map { |a| "#{a['name']} - #{a['relationship']}" }.join(', ')
  end

  def attendees_field=(string_value)
    if string_value.blank?
      self.attendees = []
      return
    end

    self.attendees = string_value.split(',').compact_blank.map do |str|
      parts = str.strip.split('-').map(&:strip)
      { 'name' => parts.first, 'relationship' => parts[1..].join('-').presence || 'Not specified' }
    end
  end

  def products_tried_field
    return [] if products_tried.blank?

    products_tried.map { |p| p['product_id'].to_i }
  end

  def products_tried_field=(array_of_ids)
    if array_of_ids.blank? || (array_of_ids.is_a?(Array) && array_of_ids.compact_blank.empty?)
      self.products_tried = []
      return
    end

    self.products_tried = Array(array_of_ids).compact_blank.map do |id|
      { 'product_id' => id.to_s, 'reaction' => 'Recorded during evaluation' }
    end
  end

  # Define method used in controller
  def request_additional_info!
    update(status: :requested)

    # Log the audit event
    AuditEventService.log(
      action: 'requested_additional_info',
      actor: evaluator,
      auditable: self,
      metadata: { evaluation_id: id }
    )

    # Send the notification
    NotificationService.create_and_deliver!(
      type: 'requested_additional_info',
      recipient: constituent,
      actor: evaluator,
      notifiable: self,
      metadata: { evaluation_id: id },
      channel: :email
    )
  end

  private

  def validate_attendees_structure
    return true unless status_completed?

    unless attendees.is_a?(Array) && attendees.all? do |attendee|
      attendee.with_indifferent_access['name'].present? && attendee.with_indifferent_access['relationship'].present?
    end
      errors.add(:attendees, 'must be an array of attendees with name and relationship when evaluation is completed')
    end
  end

  def validate_products_tried_presence
    return true unless status_completed?

    return unless !products_tried.is_a?(Array) || products_tried.empty?

    errors.add(:products_tried, "can't be blank")
  end

  def validate_products_tried_structure
    return true unless status_completed?

    unless products_tried.is_a?(Array) && products_tried.all? do |product|
      product.with_indifferent_access['product_id'].present? && product.with_indifferent_access['reaction'].present?
    end
      errors.add(:products_tried,
                 'must be an array of products tried with product_id and reaction when evaluation is completed')
    end
  end

  def update_application_record
    return unless status_completed?

    application.update!(
      needs_review_since: nil
    )
    # Additional logic to handle post-evaluation actions
  end

  def evaluator_must_be_assignable
    return if evaluator.nil?
    return if evaluator.type == 'Users::Evaluator'
    return if evaluator.type == 'Users::Administrator' && evaluator.capability?('can_evaluate')

    errors.add(:evaluator, 'must be an Evaluator or an administrator with evaluation capability')
  end

  def scheduled_time_must_be_future
    return unless evaluation_date.present? && evaluation_date <= Time.current

    errors.add(:evaluation_date, 'must be in the future')
  end

  def cannot_complete_without_notes
    return unless status_changed? && status_completed? && notes.blank?

    errors.add(:notes, 'must be provided when completing evaluation')
  end

  def set_completed_at
    self.evaluation_date = Time.current if status_completed? && evaluation_date.nil?
  end

  def status_changed_to_completed?
    status_completed? && status_changed?
  end

  def should_deliver_notifications?
    status_changed? || saved_change_to_evaluation_date?
  end

  def ensure_status_schedule_consistency
    # If setting a schedule date but still in requested status, update status
    self.status = :scheduled if evaluation_date_changed? && evaluation_date.present? && status_requested?

    # If removing a schedule date but still in scheduled/confirmed status, prevent it
    return unless evaluation_date_changed? && evaluation_date.blank? && (status_scheduled? || status_confirmed?)

    errors.add(:evaluation_date, "cannot be removed while status is #{status}")
    throw(:abort)
  end
end
