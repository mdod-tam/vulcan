# frozen_string_literal: true

# Composes user-facing messages for notifications.
# This service decouples message content from the Notification model and decorator,
# providing a single source of truth for all notification text. This makes
# testing, maintenance, and future localization much simpler.
#
# Usage:
#   NotificationComposer.generate(
#     notification.action,
#     notification.notifiable,
#     notification.actor,
#     notification.metadata
#   )
#
class NotificationComposer
  include ActionView::Helpers::TextHelper # For helpers like pluralize
  include ActionView::Helpers::UrlHelper # For link_to
  include ActionView::Helpers::OutputSafetyHelper # For safe_join

  def self.generate(notification_action, notifiable, actor = nil, metadata = {}, viewer: nil)
    new(notification_action, notifiable, actor, metadata, viewer: viewer).generate
  end

  def initialize(action, notifiable, actor, metadata, viewer: nil)
    @action = action.to_s
    @notifiable = notifiable
    @actor = actor
    @metadata = metadata || {}
    @viewer = viewer
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

  def application_reference(application = nil)
    application ||= notifiable_application
    return 'Application missing' unless application&.id

    link_to(
      application_label(application),
      application_path_for_viewer(application),
      class: 'text-indigo-600 hover:text-indigo-500 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500',
      aria: { label: "View #{application_label(application)}" }
    )
  end

  def sentence_application_reference(application = nil)
    reference = application_reference(application)
    reference == 'Application missing' ? 'application missing' : reference
  end

  def notifiable_application
    return @notifiable if @notifiable.is_a?(Application)
    return @notifiable.application if @notifiable.respond_to?(:application)

    nil
  end

  # --- Message Generation Methods ---

  def message_for_trainer_assigned
    trainer_name = @actor&.full_name || 'A trainer'
    application = @notifiable
    constituent_name = application.try(:constituent_full_name) || 'a constituent'

    training_session = find_training_session(application, @actor)
    status_info = training_session ? " (#{training_session.status.humanize})" : ''

    safe_join([trainer_name, ' assigned to train ', constituent_name, ' for ', sentence_application_reference, status_info, '.'])
  end

  def message_for_training_requested
    constituent_name = @actor&.full_name || @notifiable&.constituent_full_name || 'A constituent'
    safe_join([constituent_name, ' requested training for ', sentence_application_reference, '.'])
  end

  def message_for_training_scheduled
    training_session_message('scheduled training')
  end

  def message_for_training_rescheduled
    training_session_message('rescheduled training')
  end

  def message_for_training_cancelled
    training_session_message('cancelled training')
  end

  def message_for_training_completed
    training_session_message('completed training')
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
    safe_join([ProofNotificationCopy.approved_text(metadata_value('proof_type')), ' for ', sentence_application_reference, '.'])
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

  def message_for_medical_certification_requested
    safe_join(['Disability certification requested for ', sentence_application_reference, '.'])
  end

  def message_for_cert_upload_requested
    safe_join(['Secure disability certification upload requested for ', sentence_application_reference, '.'])
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
    safe_join(['Certifying professional information requested for ', sentence_application_reference])
  end

  def message_for_medical_certification_received
    safe_join(['Disability certification received for ', sentence_application_reference])
  end

  def message_for_medical_certification_approved
    safe_join(['Disability certification approved for ', sentence_application_reference])
  end

  def message_for_medical_certification_rejected
    reason = metadata_value('reason') || metadata_value('rejection_reason')
    reason_text = reason.present? ? " - #{reason}" : ''
    safe_join(['Disability certification rejected for ', sentence_application_reference, reason_text, '.'])
  end

  def message_for_documents_requested
    safe_join(['Documents requested for ', sentence_application_reference])
  end

  def message_for_review_requested
    safe_join(['Staff follow-up requested for ', sentence_application_reference, '.'])
  end

  def message_for_security_key_recovery_requested
    requester = @notifiable.respond_to?(:user) ? @notifiable.user : @actor
    requester_label = requester&.full_name.presence || requester&.email || 'a user'

    safe_join(['Security key recovery requested for ', requester_label, '.'])
  end

  def default_message
    reference = @notifiable.is_a?(Application) ? application_reference : generic_notifiable_reference

    safe_join([@action.humanize, ' notification regarding ', reference, '.'])
  end

  # --- Helper Methods ---

  def proof_attached_message(proof_type)
    safe_join([ProofNotificationCopy.attached_text(proof_type), ' for ', sentence_application_reference, '.'])
  end

  def proof_rejected_message(proof_type, reason)
    safe_join([
                ProofNotificationCopy.rejected_text(proof_type),
                ' for ',
                sentence_application_reference,
                ProofNotificationCopy.rejection_reason_suffix(reason),
                '.'
              ])
  end

  def proof_requested_message(proof_type)
    safe_join([ProofNotificationCopy.requested_text(proof_type), ' for ', sentence_application_reference, '.'])
  end

  def typed_proof_rejected_message(proof_type)
    proof_rejected_message(metadata_value('proof_type').presence || proof_type, metadata_value('rejection_reason'))
  end

  def application_label(application)
    label = "Application ##{application.id}"
    applicant_name = if application.respond_to?(:constituent_full_name)
                       application.constituent_full_name
                     else
                       application.user&.full_name
                     end
    applicant_name = applicant_name&.strip

    applicant_name.present? ? "#{label} (#{applicant_name})" : label
  end

  def generic_notifiable_reference
    return 'record missing' unless @notifiable

    label = @notifiable.class.name.demodulize.titleize
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

  def application_path_for_viewer(application)
    routes = Rails.application.routes.url_helpers

    if @viewer.blank? || @viewer.admin?
      routes.admin_application_path(application)
    else
      routes.constituent_portal_application_path(application)
    end
  end

  def training_session_message(verb_phrase)
    return default_message unless @notifiable.is_a?(TrainingSession)

    trainer_name = @actor&.full_name.presence ||
                   @metadata['trainer_name'].presence ||
                   preloaded_trainer_name ||
                   'A trainer'
    constituent_name = notifiable_application&.constituent_full_name.presence ||
                       @notifiable.constituent&.full_name.presence ||
                       'a constituent'
    safe_join([trainer_name, " #{verb_phrase} for ", constituent_name, ' on ', sentence_application_reference, '.'])
  end

  def preloaded_trainer_name
    return unless @notifiable.association(:trainer).loaded?

    @notifiable.trainer&.full_name.presence
  end

  def find_training_session(application, actor)
    return nil unless application.respond_to?(:training_sessions) && actor

    if application.training_sessions.loaded?
      application.training_sessions.select { |ts| ts.trainer_id == actor.id }.max_by(&:created_at)
    else
      application.training_sessions.where(trainer_id: actor.id).order(:created_at).last
    end
  end
end
