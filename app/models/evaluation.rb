# frozen_string_literal: true

class Evaluation < ApplicationRecord
  TRIAL_REACTIONS = %w[Satisfied Neutral Dissatisfied].freeze

  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  include StatusManagement

  belongs_to :evaluator, class_name: 'User'
  belongs_to :constituent, class_name: 'Users::Constituent'
  belongs_to :application
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_many :equipment_needs, foreign_key: :source_evaluation_id, inverse_of: :source_evaluation, dependent: :restrict_with_error
  has_many :equipment_items, foreign_key: :source_evaluation_id, inverse_of: :source_evaluation, dependent: :restrict_with_error
  has_and_belongs_to_many :recommended_products, class_name: 'Product', join_table: 'evaluations_products'

  enum :evaluation_type, { initial: 0, renewal: 1, special: 2 }
  enum :assessment_source, { direct_assessment: 'direct_assessment', outside_specialist: 'outside_specialist' },
       prefix: true, validate: true
  enum :recommendation_outcome,
       { catalog_products: 'catalog_products', outside_catalog: 'outside_catalog', no_suitable_product: 'no_suitable_product' },
       prefix: true, validate: true

  scope :by_report_submission, -> { order(Arel.sql('report_submitted_at DESC NULLS LAST'), updated_at: :desc) }

  # Simplified validations
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :evaluator_must_be_assignable, if: -> { new_record? || will_save_change_to_evaluator_id? }
  validate :scheduled_time_must_be_future, on: :create

  # Conditional validations for completed status
  validates :notes, presence: true, if: :status_completed?
  validates :evaluation_date, :location, presence: true, if: -> { status_completed? && assessment_source_direct_assessment? }
  validates :recommended_products, presence: true, if: -> { status_completed? && recommendation_outcome_catalog_products? }
  validates :recommendation_notes, presence: true,
                                   if: -> { status_completed? && (recommendation_outcome_outside_catalog? || recommendation_outcome_no_suitable_product?) }

  validate :validate_products_tried_presence,
           if: -> { status_completed? && assessment_source_direct_assessment? && recommendation_outcome_catalog_products? }
  validate :outside_specialist_requires_admin, if: :assessment_source_outside_specialist?
  validate :recommendations_match_outcome, if: :status_completed?
  validate :validate_available_recommendations, if: :status_changed_to_completed?
  validate :validate_attendees_structure, if: :status_completed?
  validate :validate_products_tried_structure, if: :status_completed?
  validates :appointment_completed_at, :report_submitted_at, presence: true, if: :status_changed_to_completed?
  validate :appointment_time_must_not_be_future

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

  def products_tried_inputs
    Array(products_tried).to_h do |trial|
      [trial['product_id'].to_s, { 'selected' => '1', 'reaction' => trial['reaction'] }]
    end
  end

  def products_tried_inputs=(inputs)
    @products_tried_inputs_assigned = true
    unless inputs.respond_to?(:each_pair)
      self.products_tried = nil
      return
    end

    self.products_tried = inputs.to_h.filter_map do |id, values|
      values = values.with_indifferent_access
      next unless ActiveModel::Type::Boolean.new.cast(values[:selected])

      { 'product_id' => id.to_s, 'reaction' => values[:reaction].to_s.strip.presence }
    end
  end

  # Locks the acting user, then the application, then this evaluation, the order access changes use.
  def with_actor_and_application_lock(actor, &)
    transaction do
      User.lock_for_merge_integrity!(actor) if actor&.persisted?
      application.with_lock { with_lock(&) }
    end
  end

  # True while the person still holds this evaluation and may take evaluator work.
  def assigned_to?(user)
    user.present? && evaluator_id == user.id && user.assignable_evaluator?
  end

  def working_notes_editable?
    %w[requested scheduled confirmed cancelled no_show rescheduled].include?(status)
  end

  def outside_specialist_report_allowed?(actor)
    actor&.admin? && evaluator_id == actor.id
  end

  def report_completion_allowed?(actor:, source:)
    can_complete? || (status_requested? && source == 'outside_specialist' && outside_specialist_report_allowed?(actor))
  end

  def require_approved_application!
    raise ArgumentError, 'Only approved applications can start or complete an evaluation.' unless application.status_approved?
  end

  def recommended_products_available?
    recommended_products.none?(&:archived?)
  end

  private

  def outside_specialist_requires_admin
    errors.add(:assessment_source, 'is only available to an assigned administrator') unless evaluator&.admin?
  end

  def recommendations_match_outcome
    return if recommendation_outcome_catalog_products? || recommended_products.empty?

    errors.add(:recommended_products, 'must be empty when the outcome does not recommend catalog products')
  end

  def validate_available_recommendations
    errors.add(:recommended_products, 'cannot include archived catalog products') unless recommended_products_available?
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

    valid = products_tried.is_a?(Array) && products_tried.all? do |product|
      product.is_a?(Hash) && product['product_id'].present? && (@products_tried_inputs_assigned || product['reaction'].present?)
    end
    unless valid
      errors.add(:products_tried,
                 'must be an array of products tried with product_id and reaction when evaluation is completed')
      return
    end
    return unless @products_tried_inputs_assigned

    validate_trial_reactions
    validate_trial_products
  end

  def validate_trial_reactions
    errors.add(:products_tried, 'requires a satisfaction rating for each selected product') if products_tried.any? { |trial| trial['reaction'].blank? }
    return unless products_tried.any? { |trial| trial['reaction'].present? && TRIAL_REACTIONS.exclude?(trial['reaction']) }

    errors.add(:products_tried, 'must use Satisfied, Neutral, or Dissatisfied for each selected product')
  end

  def validate_trial_products
    ids = products_tried.pluck('product_id')
    return if ids.all? { |id| id.match?(/\A[1-9]\d*\z/) } && Product.where(id: ids).count == ids.uniq.size

    errors.add(:products_tried, 'must reference catalog products')
  end

  def update_application_record
    return unless status_completed? && application.needs_review_since.present?

    # Clear only this review marker; completion does not resubmit the application's intake fields.
    return if application.update_column(:needs_review_since, nil, touch: true) # rubocop:disable Rails/SkipsModelValidations -- Review bookkeeping only.

    raise ActiveRecord::RecordNotSaved.new('Evaluation review clearance was not recorded.', application)
  end

  # Checked for a new or changed assignee only, so a former assignee who lost eligibility can still be cancelled or edited.
  def evaluator_must_be_assignable
    return if evaluator.nil?
    return if evaluator.assignable_evaluator?

    errors.add(:evaluator, 'must be an active staff member with evaluation capability')
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
