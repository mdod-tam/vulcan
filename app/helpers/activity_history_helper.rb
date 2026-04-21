# frozen_string_literal: true

module ActivityHistoryHelper
  ACTIVITY_LABELS = {
    'training_scheduled' => 'Training Scheduled',
    'training_completed' => 'Training Completed',
    'training_cancelled' => 'Training Cancelled',
    'training_rescheduled' => 'Training Rescheduled',
    'training_no_show' => 'No Show',
    'training_missed' => 'No Show',
    'evaluation_scheduled' => 'Evaluation Scheduled',
    'evaluation_completed' => 'Evaluation Completed',
    'evaluation_rescheduled' => 'Evaluation Rescheduled',
    'requested_additional_info' => 'Additional Info Requested',
    'evaluator_assigned' => 'Evaluator Assigned',
    'equipment_bids_sent' => 'Equipment Bids Sent',
    'equipment_po_sent' => 'PO Sent to Vendor'
  }.freeze

  APPLICATION_ACTIONS = %w[evaluator_assigned].freeze
  APPLICATION_FULFILLMENT_ACTIONS = %w[equipment_bids_sent equipment_po_sent].freeze

  def activity_label(event)
    ACTIVITY_LABELS.fetch(event.action, event.action.to_s.titleize)
  end

  def activity_detail(event)
    metadata = activity_metadata(event)

    details = case event.action
              when 'training_scheduled'
                scheduled_detail(metadata, 'scheduled_for', 'Scheduled for')
              when 'training_completed'
                completed_training_detail(metadata)
              when 'training_cancelled'
                cancellation_detail(metadata)
              when 'training_rescheduled'
                rescheduled_detail(metadata, old_key: 'old_scheduled_for', new_key: 'new_scheduled_for')
              when 'training_no_show', 'training_missed'
                metadata_value(metadata, 'no_show_notes').presence || 'Marked as no show'
              when 'evaluation_scheduled'
                scheduled_detail(metadata, 'evaluation_date', 'Scheduled for')
              when 'evaluation_rescheduled'
                rescheduled_detail(metadata, old_key: 'old_evaluation_date', new_key: 'evaluation_date')
              when 'evaluation_completed'
                completed_evaluation_detail(metadata)
              when 'requested_additional_info'
                'Additional information requested from the constituent'
              when 'evaluator_assigned'
                evaluator_assigned_detail(metadata)
              when 'equipment_bids_sent'
                date_detail(metadata, 'date', 'Bids sent')
              when 'equipment_po_sent'
                date_detail(metadata, 'date', 'PO sent')
              end

    details.presence || 'No additional details recorded'
  end

  def activity_actor_name(event)
    event.user&.full_name.presence || 'System'
  end

  def activity_subject_name(event)
    activity_subject_record(event)&.then do |record|
      constituent_name_for(record)
    end.presence || 'Unknown constituent'
  end

  def activity_source_label(event)
    return 'Application Fulfillment' if APPLICATION_FULFILLMENT_ACTIONS.include?(event.action)

    'Application' if APPLICATION_ACTIONS.include?(event.action)
  end

  private

  def activity_metadata(event)
    event.metadata.to_h.with_indifferent_access
  end

  def metadata_value(metadata, key)
    metadata[key].presence
  end

  def activity_subject_record(event)
    return event.auditable if event.respond_to?(:auditable) && event.auditable.present?

    metadata = activity_metadata(event)
    return Evaluation.includes(:constituent).find_by(id: metadata['evaluation_id']) if metadata['evaluation_id'].present?
    return TrainingSession.includes(application: :user).find_by(id: metadata['training_session_id']) if metadata['training_session_id'].present?

    Application.includes(:user).find_by(id: metadata['application_id']) if metadata['application_id'].present?
  end

  def constituent_name_for(record)
    case record
    when Evaluation, TrainingSession
      record.constituent&.full_name
    when Application
      record.constituent_full_name
    end
  end

  def scheduled_detail(metadata, date_key, prefix)
    parts = []
    parts << "#{prefix} #{format_activity_time(metadata_value(metadata, date_key))}" if metadata_value(metadata, date_key)
    parts << "Location: #{metadata_value(metadata, 'location')}" if metadata_value(metadata, 'location')
    parts << "Notes: #{metadata_value(metadata, 'notes')}" if metadata_value(metadata, 'notes')
    parts.join('. ')
  end

  def completed_training_detail(metadata)
    parts = []
    parts << "Completed #{format_activity_time(metadata_value(metadata, 'completed_at'))}" if metadata_value(metadata, 'completed_at')
    parts << "Product: #{metadata_value(metadata, 'product_trained_on')}" if metadata_value(metadata, 'product_trained_on')
    parts << "Notes: #{metadata_value(metadata, 'notes')}" if metadata_value(metadata, 'notes')
    parts.join('. ')
  end

  def completed_evaluation_detail(metadata)
    parts = []
    parts << "Completed #{format_activity_time(metadata_value(metadata, 'evaluation_date'))}" if metadata_value(metadata, 'evaluation_date')
    parts << "Products tried: #{metadata_value(metadata, 'products_tried_count')}" if metadata.key?('products_tried_count')
    parts << "Recommended products: #{metadata_value(metadata, 'recommended_products_count')}" if metadata.key?('recommended_products_count')
    parts << "Recommended: #{Array(metadata['recommended_product_names']).join(', ')}" if metadata['recommended_product_names'].present?
    parts.join('. ')
  end

  def cancellation_detail(metadata)
    metadata_value(metadata, 'cancellation_reason').presence || 'Training cancelled'
  end

  def rescheduled_detail(metadata, old_key:, new_key:)
    parts = []
    reason = metadata_value(metadata, 'reason') || metadata_value(metadata, 'reschedule_reason')
    parts << "From #{format_activity_time(metadata_value(metadata, old_key))}" if metadata_value(metadata, old_key)
    parts << "To #{format_activity_time(metadata_value(metadata, new_key))}" if metadata_value(metadata, new_key)
    parts << "Reason: #{reason}" if reason
    parts << "Location: #{metadata_value(metadata, 'location')}" if metadata_value(metadata, 'location')
    parts.join('. ')
  end

  def evaluator_assigned_detail(metadata)
    evaluator_name = metadata_value(metadata, 'evaluator_name')
    evaluator_name.present? ? "Evaluator #{evaluator_name} assigned" : 'Evaluator assigned'
  end

  def date_detail(metadata, key, prefix)
    return prefix unless metadata_value(metadata, key)

    "#{prefix} on #{format_activity_date(metadata_value(metadata, key))}"
  end

  def format_activity_time(value)
    parse_activity_time(value)&.strftime('%B %d, %Y at %I:%M %p') || value.to_s
  end

  def format_activity_date(value)
    parse_activity_time(value)&.strftime('%B %d, %Y') || value.to_s
  end

  def parse_activity_time(value)
    return value.in_time_zone if value.respond_to?(:in_time_zone)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
