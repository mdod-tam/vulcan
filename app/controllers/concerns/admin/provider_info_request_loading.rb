# frozen_string_literal: true

module Admin
  module ProviderInfoRequestLoading
    extend ActiveSupport::Concern

    private

    def load_provider_info_request_data(application)
      unless application.missing_required_provider_info?
        @provider_info_guardian_relationships = []
        @provider_info_recipient_options = []
        @secure_request_forms = []
        @active_secure_request_form_batch_counts = {}
        @provider_info_needs_managing_guardian = false
        return
      end

      @provider_info_guardian_relationships = provider_info_guardian_relationships(application)
      @provider_info_recipient_options = provider_info_recipient_options(application, @provider_info_guardian_relationships)
      @secure_request_forms = application
                              .secure_request_forms
                              .provider_info
                              .includes(:recipient)
                              .order(sent_at: :desc)
      @active_secure_request_form_batch_counts = application
                                                 .secure_request_forms
                                                 .provider_info
                                                 .active
                                                 .group(:request_batch_id)
                                                 .count
      @provider_info_needs_managing_guardian = application.managing_guardian_id.blank? &&
                                               @provider_info_guardian_relationships.many?
    end

    def provider_info_request_summaries_for(applications)
      application_ids = applications.map(&:id)
      return {} if application_ids.blank?

      pending_ids = Application.pending_provider_info.where(id: application_ids).pluck(:id)
      summaries = pending_ids.index_with { provider_info_empty_summary }
      return summaries if pending_ids.blank?

      provider_info_latest_batch_forms(pending_ids).each do |application_id, batch_forms|
        summaries[application_id] = provider_info_batch_summary(batch_forms)
      end
      summaries
    end

    def provider_info_guardian_relationships(application)
      GuardianRelationship
        .includes(:guardian_user)
        .where(dependent_id: application.user_id)
        .to_a
    end

    def provider_info_recipient_options(application, guardian_relationships)
      resolver = Applications::SecureRequestRecipientResolver.new(
        application: application,
        guardian_relationships: guardian_relationships
      )
      known_recipients = resolver.known_recipients
      default_candidates = Applications::SecureRequestRecipientResolver
                           .new(
                             application: application,
                             recipient_ids: known_recipients.map(&:id),
                             known_recipients: known_recipients,
                             guardian_relationships: guardian_relationships
                           )
                           .resolve
                           .index_by { |candidate| candidate.recipient.id }

      known_recipients.map do |recipient|
        default_candidate = default_candidates[recipient.id]
        {
          recipient: recipient,
          candidate: default_candidate,
          email_override_available: default_candidate&.email_override_available? || false
        }
      end
    end

    def provider_info_latest_batch_forms(application_ids)
      SecureRequestForm
        .provider_info
        .where(application_id: application_ids)
        .order(sent_at: :desc)
        .to_a
        .group_by(&:application_id)
        .transform_values do |forms|
          latest_batch_id = forms.max_by(&:sent_at)&.request_batch_id
          forms.select { |form| form.request_batch_id == latest_batch_id }
        end
    end

    def provider_info_empty_summary
      {
        pending: true,
        recipient_count: 0,
        status_counts: { active: 0, submitted: 0, expired: 0, revoked: 0 },
        last_sent_at: nil,
        nearest_expiration_at: nil
      }
    end

    def provider_info_batch_summary(batch_forms)
      status_counts = { active: 0, submitted: 0, expired: 0, revoked: 0 }
      batch_forms.each { |form| status_counts[form.display_status] += 1 }

      active_expirations = batch_forms.select(&:active?).filter_map(&:expires_at)
      {
        pending: true,
        recipient_count: batch_forms.size,
        status_counts: status_counts,
        last_sent_at: batch_forms.filter_map(&:sent_at).max,
        nearest_expiration_at: active_expirations.min || batch_forms.filter_map(&:expires_at).min
      }
    end
  end
end
