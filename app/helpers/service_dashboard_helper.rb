# frozen_string_literal: true

module ServiceDashboardHelper
  def service_dashboard_disabilities(application)
    labels = application.program_disability_groups.filter_map do |group|
      t("service_dashboard.groups.#{group}") if Product::PROGRAM_GROUPS.key?(group)
    end
    labels.to_sentence.presence || t('service_dashboard.disability_unknown')
  end

  def service_dashboard_average(days)
    return t('service_dashboard.not_recorded') unless days

    value = number_with_precision(days, precision: 1, strip_insignificant_zeros: true)
    t('service_dashboard.days', count: days, value:)
  end

  def service_dashboard_practitioner_label(entry)
    role = entry.record.is_a?(Evaluation) ? 'evaluator' : 'trainer'
    t("service_dashboard.practitioner.#{role}", name: entry.practitioner&.full_name || t('service_dashboard.not_recorded'))
  end

  def training_dashboard_entry_path(entry, request_sessions:)
    return unless entry
    return trainers_training_session_path(entry.record) if entry.record
    return admin_application_path(entry.application, anchor: 'admin-training-heading') if current_user.admin?

    trainers_training_session_path(request_sessions.fetch(entry.application.id))
  end
end
