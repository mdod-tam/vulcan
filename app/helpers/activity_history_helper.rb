# frozen_string_literal: true

module ActivityHistoryHelper
  ACTIVITY_LABELS = {
    'training_scheduled' => 'Training Scheduled',
    'training_completed' => 'Training Completed',
    'training_cancelled' => 'Training Cancelled',
    'training_rescheduled' => 'Training Rescheduled',
    'training_followup_scheduled' => 'Follow-up Training Scheduled',
    'training_no_show' => 'No show',
    'training_missed' => 'No show',
    'evaluation_scheduled' => 'Evaluation Scheduled',
    'evaluation_completed' => 'Evaluation Completed',
    'evaluation_cancelled' => 'Evaluation Cancelled',
    'evaluation_no_show' => 'Evaluation No-Show',
    'evaluation_rescheduled' => 'Evaluation Rescheduled',
    'requested_additional_info' => 'Additional Info Requested',
    'evaluator_assigned' => 'Evaluator Assigned',
    'evaluator_reassigned' => 'Evaluator Reassigned',
    'evaluation_working_notes_updated' => 'Working Notes Updated'
  }.freeze

  APPLICATION_ACTIONS = %w[evaluator_assigned].freeze
  STATIC_ACTIVITY_DETAILS = {
    'requested_additional_info' => 'Additional information requested from the constituent',
    'evaluator_reassigned' => 'Evaluation transferred to another evaluator',
    'evaluation_working_notes_updated' => 'Internal working notes updated'
  }.freeze

  def activity_label(event)
    I18n.t(
      "activity_history.labels.#{event.action}",
      default: ACTIVITY_LABELS.fetch(event.action, event.action.to_s.titleize)
    )
  end

  def activity_detail(event)
    metadata = activity_metadata(event)

    details = case event.action
              when 'training_scheduled'
                training_scheduled_detail(metadata)
              when 'training_completed'
                completed_training_detail(metadata)
              when 'training_cancelled'
                training_cancellation_detail(metadata)
              when 'evaluation_cancelled'
                cancellation_detail(metadata)
              when 'training_rescheduled'
                training_rescheduled_detail(metadata)
              when 'training_followup_scheduled'
                followup_scheduled_detail(metadata)
              when 'training_no_show', 'training_missed'
                I18n.t('training_activity.no_show')
              when 'evaluation_no_show'
                metadata_value(metadata, 'no_show_notes').presence || 'Marked as no-show'
              when 'evaluation_scheduled'
                scheduled_detail(metadata, 'evaluation_date', 'Scheduled for')
              when 'evaluation_rescheduled'
                rescheduled_detail(metadata, old_key: 'old_evaluation_date', new_key: 'evaluation_date')
              when 'evaluation_completed'
                completed_evaluation_detail(metadata)
              when 'evaluator_assigned'
                evaluator_assigned_detail(metadata)
              end

    details.presence || STATIC_ACTIVITY_DETAILS.fetch(event.action, I18n.t('activity_history.table.no_details'))
  end

  def activity_actor_name(event)
    event.user&.full_name.presence || I18n.t('activity_history.table.system')
  end

  def activity_subject_name(event)
    activity_subject_record(event)&.then do |record|
      constituent_name_for(record)
    end.presence || I18n.t('activity_history.table.unknown_constituent')
  end

  def activity_source_label(event)
    I18n.t('activity_history.table.application') if APPLICATION_ACTIONS.include?(event.action)
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

  def training_scheduled_detail(metadata)
    return unless metadata_value(metadata, 'scheduled_for')

    I18n.t('training_activity.scheduled_for', time: format_training_activity_time(metadata['scheduled_for']))
  end

  def followup_scheduled_detail(metadata)
    return unless metadata_value(metadata, 'scheduled_for')

    I18n.t('training_activity.followup_scheduled_for', time: format_training_activity_time(metadata['scheduled_for']))
  end

  def training_rescheduled_detail(metadata)
    parts = []
    parts << I18n.t('training_activity.rescheduled_from', time: format_training_activity_time(metadata['old_scheduled_for'])) if metadata_value(metadata,
                                                                                                                                                'old_scheduled_for')
    parts << I18n.t('training_activity.rescheduled_to', time: format_training_activity_time(metadata['new_scheduled_for'])) if metadata_value(metadata,
                                                                                                                                              'new_scheduled_for')
    parts.join('. ')
  end

  def training_cancellation_detail(metadata)
    initiator = metadata_value(metadata, 'cancellation_initiator')
    return I18n.t('training_activity.cancelled') unless %w[constituent trainer admin program].include?(initiator.to_s)

    I18n.t('training_activity.cancelled_by', initiator: I18n.t("training_activity.initiators.#{initiator}"))
  end

  def completed_training_detail(metadata)
    parts = []
    parts << I18n.t('training_activity.actual_completion', time: format_training_activity_time(metadata['completed_at'])) if metadata_value(metadata, 'completed_at')
    parts << I18n.t('training_activity.report_submitted', time: format_training_activity_time(metadata['report_submitted_at'])) if metadata_value(metadata,
                                                                                                                                                  'report_submitted_at')
    parts << I18n.t('training_activity.duration', hours: metadata['duration_hours']) if metadata_value(metadata, 'duration_hours')
    parts << I18n.t('training_activity.product', id: metadata['product_trained_on_id']) if metadata_value(metadata, 'product_trained_on_id')
    parts.join('. ')
  end

  def format_training_activity_time(value)
    time = parse_activity_time(value)
    time ? I18n.l(time, format: :long) : I18n.t('training_activity.time_unavailable')
  end

  def completed_evaluation_detail(metadata)
    parts = []
    parts << "Scheduled for #{format_activity_time(metadata_value(metadata, 'evaluation_date'))}" if metadata_value(metadata, 'evaluation_date')
    parts << "Appointment completed #{format_activity_time(metadata_value(metadata, 'appointment_completed_at'))}" if metadata_value(metadata, 'appointment_completed_at')
    parts << "Report submitted #{format_activity_time(metadata_value(metadata, 'report_submitted_at'))}" if metadata_value(metadata, 'report_submitted_at')
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

  def format_activity_time(value)
    parse_activity_time(value)&.strftime('%B %d, %Y at %I:%M %p') || value.to_s
  end

  def parse_activity_time(value)
    return value.in_time_zone if value.respond_to?(:in_time_zone)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
