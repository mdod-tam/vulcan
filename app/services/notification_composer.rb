# frozen_string_literal: true

# Composes notification text in one place, so the Notification model and
# decorator carry no copy of their own.
class NotificationComposer
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::UrlHelper
  include ActionView::Helpers::OutputSafetyHelper

  def self.generate(notification_action, notifiable, actor = nil, metadata = {}, viewer: nil, locale: nil)
    new(notification_action, notifiable, actor, metadata, viewer: viewer, locale: locale).generate
  end

  def initialize(action, notifiable, actor, metadata, viewer: nil, locale: nil)
    @action = action.to_s
    @notifiable = notifiable
    @actor = actor
    @metadata = metadata || {}
    @viewer = viewer
    @locale = locale
  end

  def generate
    method_name = "message_for_#{@action}"
    if respond_to?(method_name, true)
      send(method_name)
    else
      default_message
    end
  end

  private

  def message_for_voucher_expired
    translate('voucher_expired')
  end

  def application_reference(application = nil)
    application ||= notifiable_application
    return translate('application_missing') unless application&.id

    label = application_label(application)
    link_to(label, application_path_for_viewer(application), class: 'text-primary-600 hover:text-primary-500',
                                                             aria: { label: translate('view_application', application: label) })
  end

  def sentence_application_reference(application = nil)
    application ||= notifiable_application
    application&.id ? application_reference(application) : translate('sentence_application_missing')
  end

  def notifiable_application
    return @notifiable if @notifiable.is_a?(Application)
    return @notifiable.application if @notifiable.respond_to?(:application)

    nil
  end

  def message_for_trainer_assigned
    return default_message unless @notifiable.is_a?(TrainingSession)

    reference = link_to(translate('training_reference', name: @notifiable.constituent.full_name),
                        Rails.application.routes.url_helpers.trainers_training_session_path(@notifiable))
    translate('trainer_assigned_html', trainer: @notifiable.trainer.full_name, training: reference)
  end

  def message_for_trainer_reassigned
    return default_message unless @notifiable.is_a?(TrainingSession)

    reference = link_to(translate('training_transfer_reference', name: @notifiable.constituent.full_name),
                        Rails.application.routes.url_helpers.trainers_training_session_path(@notifiable))
    translate('trainer_reassigned_html', training: reference)
  end

  def message_for_training_trainer_changed
    trainer_name = @metadata['trainer_name'].presence || translate('another_trainer')
    translate('training_trainer_changed_html', trainer: trainer_name)
  end

  def message_for_training_requested
    name = @actor&.full_name || @notifiable&.constituent_full_name || translate('a_constituent')
    translate('training_requested_html', name: name, application: sentence_application_reference)
  end

  def message_for_training_scheduled
    training_session_message('training_scheduled_html')
  end

  def message_for_training_rescheduled
    training_session_message('training_rescheduled_html')
  end

  def message_for_training_cancelled
    training_session_message('training_cancelled_html')
  end

  def message_for_training_completed
    training_session_message('training_completed_html')
  end

  def message_for_proof_rejected
    proof_rejected_message(metadata_value('proof_type'), metadata_value('rejection_reason'))
  end

  def message_for_id_proof_rejected
    typed_proof_rejected_message('id')
  end

  def message_for_income_proof_rejected
    typed_proof_rejected_message('income')
  end

  def message_for_residency_proof_rejected
    typed_proof_rejected_message('residency')
  end

  def message_for_proof_approved
    translate('proof_status_html', status: ProofNotificationCopy.approved_text(metadata_value('proof_type'), locale: message_locale),
                                   application: sentence_application_reference)
  end

  def message_for_id_proof_attached
    proof_attached_message('id')
  end

  def message_for_income_proof_attached
    proof_attached_message('income')
  end

  def message_for_residency_proof_attached
    proof_attached_message('residency')
  end

  def message_for_disability_certification_requested
    translate('disability_certification_requested_html', application: sentence_application_reference)
  end

  def message_for_cert_upload_requested
    translate('cert_upload_requested_html', application: sentence_application_reference)
  end

  def message_for_proof_resubmission_requested
    proof_type = metadata_value('proof_type')
    reason = proof_resubmission_rejection_reason(proof_type)

    if proof_resubmission_rejected?
      proof_rejected_message(proof_type, reason)
    else
      proof_requested_message(proof_type)
    end
  end

  def message_for_provider_info_requested
    translate('provider_info_requested_html', application: sentence_application_reference)
  end

  def message_for_disability_certification_received
    translate('disability_certification_received_html', application: sentence_application_reference)
  end

  def message_for_disability_certification_approved
    translate('disability_certification_approved_html', application: sentence_application_reference)
  end

  def message_for_disability_certification_rejected
    translate('disability_certification_rejected_html', application: sentence_application_reference,
                                                        reason: ProofNotificationCopy.rejection_reason_suffix(metadata_value('rejection_reason'), locale: message_locale))
  end

  def message_for_documents_requested
    translate('documents_requested_html', application: sentence_application_reference)
  end

  def message_for_review_requested
    translate('review_requested_html', application: sentence_application_reference)
  end

  def message_for_security_key_recovery_requested
    requester = @notifiable.respond_to?(:user) ? @notifiable.user : @actor
    translate('security_key_recovery_requested_html', name: requester&.full_name.presence || requester&.email || translate('a_user'))
  end

  def default_message
    reference = @notifiable.is_a?(Application) ? application_reference : generic_notifiable_reference
    action = I18n.t("notifications.actions.#{@action}", locale: message_locale, default: @action.humanize)
    translate('default_html', action: action, record: reference)
  end

  def proof_attached_message(proof_type)
    translate('proof_status_html', status: ProofNotificationCopy.attached_text(proof_type, locale: message_locale),
                                   application: sentence_application_reference)
  end

  def proof_rejected_message(proof_type, reason)
    translate('proof_rejected_html', proof: ProofNotificationCopy.proof_label(proof_type, locale: message_locale),
                                     application: sentence_application_reference, reason: ProofNotificationCopy.rejection_reason_suffix(reason, locale: message_locale))
  end

  def proof_requested_message(proof_type)
    translate('proof_status_html', status: ProofNotificationCopy.requested_text(proof_type, locale: message_locale),
                                   application: sentence_application_reference)
  end

  def typed_proof_rejected_message(proof_type)
    proof_rejected_message(metadata_value('proof_type').presence || proof_type, metadata_value('rejection_reason'))
  end

  def application_label(application)
    name = application.constituent_full_name.strip
    key = name.present? ? 'application_named' : 'application'
    translate(key, id: application.id, name: name)
  end

  def generic_notifiable_reference
    return translate('record_missing') unless @notifiable

    label = @notifiable.class.model_name.human
    @notifiable.id ? "#{label} ##{@notifiable.id}" : label
  end

  def metadata_value(key)
    key = key.to_s
    @metadata[key] ||
      @metadata[key.to_sym] ||
      template_variables_value(key) ||
      template_variables_value(template_variable_alias_for(key))
  end

  def proof_resubmission_rejection_reason(proof_type)
    return unless Notification.proof_resubmission_rejected_metadata?(@metadata)

    metadata_value('rejection_reason').presence || latest_rejected_proof_review(proof_type)&.rejection_reason
  end

  def latest_rejected_proof_review(proof_type)
    application = notifiable_application
    proof_type = proof_type.to_s
    return if proof_type.blank? || !application.is_a?(Application)

    if application.association(:proof_reviews).loaded?
      application.proof_reviews
                 .select { |review| review.proof_type == proof_type && review.status_rejected? }
                 .max_by { |review| [review.updated_at || review.created_at, review.created_at] }
    else
      application.proof_reviews
                 .where(proof_type: proof_type, status: :rejected)
                 .order(updated_at: :desc, created_at: :desc)
                 .first
    end
  end

  def proof_resubmission_rejected?
    Notification.proof_resubmission_rejected_metadata?(@metadata)
  end

  def template_variables_value(key)
    return if key.blank?

    variables = @metadata['template_variables'] || @metadata[:template_variables]
    return unless variables.respond_to?(:[])

    variables[key.to_s] || variables[key.to_sym]
  end

  def template_variable_alias_for(key)
    key.to_s == 'proof_type' ? 'proof_type_formatted' : nil
  end

  # A trainer, or an evaluator granted training. Administrators keep the admin application page.
  def trainer_viewer?
    @viewer.can_train? && !@viewer.admin?
  end

  def application_path_for_viewer(application)
    routes = Rails.application.routes.url_helpers

    if application.current_trainer?(@viewer) && (trainer_viewer? || (@action == 'training_requested' && metadata_value('recipient_audience') == 'assigned_trainer'))
      routes.trainers_training_session_path(application.latest_training_session)
    elsif @viewer.blank? || @viewer.admin?
      routes.admin_application_path(application)
    else
      routes.constituent_portal_application_path(application)
    end
  end

  def training_session_message(key)
    return default_message unless @notifiable.is_a?(TrainingSession)

    trainer_name = @actor&.full_name.presence || @metadata['trainer_name'].presence || preloaded_trainer_name || translate('a_trainer')
    name = notifiable_application&.constituent_full_name.presence || @notifiable.constituent&.full_name.presence || translate('constituent')
    translate(key, trainer: trainer_name, name: name, application: sentence_application_reference)
  end

  def message_for_max_rejections_reached
    translate('max_rejections_reached_html', application: application_reference)
  end

  def message_for_initial_voucher_issuance_attention
    translate('initial_voucher_issuance_attention_html', application: application_reference)
  end

  def message_locale
    @locale || @viewer&.effective_message_locale || I18n.locale
  end

  def preloaded_trainer_name
    return unless @notifiable.association(:trainer).loaded?

    @notifiable.trainer&.full_name.presence
  end

  # Rails escapes interpolations in _html translations while preserving generated links.
  def translate(key, **variables)
    ActionController::Base.helpers.t("notifications.messages.#{key}", locale: message_locale, **variables)
  end
end
