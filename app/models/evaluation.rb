# frozen_string_literal: true

class Evaluation < ApplicationRecord
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  include StatusManagement

  belongs_to :evaluator, class_name: 'User'
  belongs_to :constituent, class_name: 'Users::Constituent'
  belongs_to :application
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_and_belongs_to_many :recommended_products, class_name: 'Product', join_table: 'evaluations_products'

  enum :evaluation_type, { initial: 0, renewal: 1, special: 2 }
  enum :recommendation_outcome,
       { catalog_products: 'catalog_products', outside_catalog: 'outside_catalog', no_suitable_product: 'no_suitable_product' },
       prefix: true, validate: true

  scope :by_report_submission, -> { order(Arel.sql('report_submitted_at DESC NULLS LAST'), updated_at: :desc) }

  # Simplified validations
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :evaluator_must_be_assignable
  validate :scheduled_time_must_be_future, on: :create

  # Conditional validations for completed status
  validates :evaluation_date,
            :location,
            :notes,
            presence: true,
            if: :status_completed?
  validates :recommended_products, presence: true, if: -> { status_completed? && recommendation_outcome_catalog_products? }
  validates :recommendation_notes, presence: true,
                                   if: -> { status_completed? && (recommendation_outcome_outside_catalog? || recommendation_outcome_no_suitable_product?) }

  validate :validate_products_tried_presence, if: -> { status_completed? && recommendation_outcome_catalog_products? }
  validate :recommendations_match_outcome, if: :status_completed?
  validate :validate_attendees_structure, if: :status_completed?
  validate :validate_products_tried_structure, if: :status_completed?
  validates :appointment_completed_at, :report_submitted_at, presence: true, if: :status_changed_to_completed?
  validate :appointment_time_must_not_be_future

  # Callbacks
  before_save :ensure_status_schedule_consistency
  after_save :update_application_record, if: :saved_change_to_status?

  # Virtual attributes for UI
  def attendees_field
    return '' if attendees.blank?

    attendee_display_values.join(', ')
  end

  def attendees_field=(string_value)
    if string_value.blank?
      self.attendees = []
      return
    end

    self.attendees = string_value.split(',').compact_blank.map do |str|
      { 'name' => str.strip }
    end
  end

  def attendee_display_values
    Array(attendees).filter_map { |attendee| attendee_display_text(attendee).presence }
  end

  def attendee_display_text(attendee)
    return attendee if attendee.is_a?(String)
    return unless attendee.respond_to?(:with_indifferent_access)

    attendee_hash = attendee.with_indifferent_access
    name = attendee_hash[:name].presence
    relationship = attendee_hash[:relationship].presence

    return name if name && relationship == 'Not specified'
    return "#{name} - #{relationship}" if name && relationship

    name || relationship
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

  def working_notes_editable?
    %w[requested scheduled confirmed cancelled no_show rescheduled].include?(status)
  end

  private

  def recommendations_match_outcome
    return if recommendation_outcome_catalog_products? || recommended_products.empty?

    errors.add(:recommended_products, 'must be empty when the outcome does not recommend catalog products')
  end

  def validate_attendees_structure
    return true unless status_completed?

    valid_attendees = attendees.is_a?(Array) && attendees.all? { |attendee| attendee_display_text(attendee).present? }
    return if valid_attendees

    errors.add(:attendees, 'must be an array of attendee descriptions when evaluation is completed')
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
    return if evaluator.assignable_evaluator?

    errors.add(:evaluator, 'must be an Evaluator or an administrator with evaluation capability')
  end

  def scheduled_time_must_be_future
    return unless evaluation_date.present? && evaluation_date <= Time.current

    errors.add(:evaluation_date, 'must be in the future')
  end

  def appointment_time_must_not_be_future
    return unless appointment_completed_at&.future?

    errors.add(:appointment_completed_at, 'cannot be in the future')
  end

  def status_changed_to_completed?
    status_completed? && status_changed?
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
