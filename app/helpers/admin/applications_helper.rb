# frozen_string_literal: true

module Admin
  module ApplicationsHelper
    include RejectionReasonsHelper

    MedicalCertificationActionState = Struct.new(
      :latest_certification_request,
      :latest_certification_reject,
      :requested_after_rejection,
      :provider_ready_for_docuseal,
      :docuseal_text,
      :secure_cert_upload_message,
      :active_secure_cert_upload_forms,
      :docuseal_confirm,
      :secure_cert_upload_confirm
    ) do
      alias_method :requested_after_rejection?, :requested_after_rejection
      alias_method :provider_ready_for_docuseal?, :provider_ready_for_docuseal
    end

    def medical_certification_link(application, style = :link)
      return nil unless application.medical_certification.attached?

      host = if Rails.env.production?
               # Fail fast if APPLICATION_HOST is not configured in production
               ENV.fetch('APPLICATION_HOST')
             else
               # For non-production environments, use request.host if available
               Rails.application.routes.default_url_options[:host] || (defined?(request) && request.host)
             end

      url = Rails.application.routes.url_helpers.rails_blob_path(
        application.medical_certification,
        disposition: :inline,
        host: host
      )

      if style == :button
        # Use classes similar to other full-height buttons in the form
        button_classes = [
          'inline-flex justify-center py-2 px-4 border border-transparent shadow-sm',
          'text-sm font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700',
          'focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500'
        ].join(' ')

        link_to 'View Medical Certification Document', url,
                target: '_blank',
                class: button_classes,
                rel: 'noopener'
      else
        link_to 'View Medical Certification Document', url,
                target: '_blank',
                class: 'text-blue-600 hover:text-blue-800 underline',
                rel: 'noopener'
      end
    end

    def medical_certification_submission_method(application)
      return 'unknown' unless application.medical_certification.attached?

      # Try to find submission method from metadata or related records
      if application.respond_to?(:medical_certification_submission_method) &&
         application.medical_certification_submission_method.present?
        return application.medical_certification_submission_method
      end

      # Check for status changes that might have the method
      status_change = ApplicationStatusChange.where(application_id: application.id)
                                             .where("metadata->>'change_type' = ? OR to_status = ?",
                                                    'medical_certification', 'received')
                                             .order(created_at: :desc)
                                             .first

      if status_change&.metadata.present? &&
         status_change.metadata['submission_method'].present?
        return status_change.metadata['submission_method']
      end

      # Default fallback
      'portal'
    end

    def format_rejection_reason(proof_type, application)
      proof_status_method = "#{proof_type}_proof_status"
      return nil unless application.respond_to?(proof_status_method)
      return nil unless application.send(proof_status_method) == 'rejected'

      proof_review = application.proof_reviews.where(proof_type: proof_type, status: 'rejected').order(created_at: :desc).first
      proof_review&.rejection_reason || 'Reason unavailable'
    end

    def format_review_status(proof_type, application)
      proof_status_method = "#{proof_type}_proof_status"
      return 'Pending' unless application.respond_to?(proof_status_method)

      status = application.send(proof_status_method)
      case status
      when 'approved'
        'Approved'
      when 'rejected'
        'Rejected'
      else
        'Pending'
      end
    end

    def proof_reviewer_actions_html(proof_type, application)
      # Already wrapped in if/else statement
      proof_status_method = "#{proof_type}_proof_status"
      case application.send(proof_status_method)
      when 'approved'
        link_to 'View Approved Proof',
                rails_blob_path(application.send("#{proof_type}_proof"), disposition: :inline),
                target: '_blank',
                class: 'btn btn-success btn-sm', rel: 'noopener'
      when 'pending'
        content_tag(:span, 'Manual review required',
                    class: 'badge badge-pill badge-warning')
      when 'rejected'
        latest_review = application.proof_reviews.where(proof_type: proof_type, status: 'rejected').order(created_at: :desc).first
        if latest_review
          content_tag(:div) do
            safe_join([
                        "Rejected on #{latest_review.created_at.strftime('%B %d, %Y')} by #{latest_review.admin&.email || 'Unknown'}",
                        content_tag(:div, class: 'mt-2') do
                          link_to 'Review Again',
                                  'javascript:;',
                                  class: 'btn btn-primary btn-sm',
                                  data: {
                                    toggle: 'modal',
                                    target: "##{proof_type}ProofReviewModal"
                                  }
                        end
                      ])
          end
        else
          content_tag(:span, 'Rejected',
                      class: 'badge badge-pill badge-danger')
        end
      else
        'Unknown Status'
      end
    end

    def toggle_direction(column)
      # Check if the current sort column matches the link's column
      # and if the current direction is ascending.
      if params[:sort] == column.to_s && params[:direction] == 'asc'
        'desc' # If so, set the link's direction to descending
      else
        'asc'  # Otherwise, set the link's direction to ascending (default)
      end
    end

    # Get proof history in chronological order (oldest first) with deduplication
    def get_chronological_proof_history(application, proof_type)
      ConstituentPortal::Activity
        .from_events(application)
        .select { |activity| activity.proof_type.to_s == proof_type.to_s }
    end

    def show_proof_history_submission_fallback?(application, proof_type)
      application.public_send("#{proof_type}_proof").attached? && application.created_at.present?
    end

    def format_proof_history_detail(detail, application)
      text = RejectionReason.interpolate_body(
        detail.to_s,
        address: application_proof_history_address(application)
      ).to_s.strip

      text.gsub(/\A"(.*)"\z/m, '\1')
    end

    def calculate_percentage(count, total)
      return 0 unless total.positive?

      number_to_percentage((count.to_f / total) * 100, precision: 1)
    end

    def application_status_options
      Application.statuses.keys.map { |s| [s.titleize, s] }
    end

    def application_type_options
      Application.application_types.keys.map { |s| [s.titleize, s] }
    end

    def submission_method_options
      Application.submission_methods.keys.map { |s| [s.titleize, s] }
    end

    def docuseal_button_text(application)
      case application.document_signing_status
      when 'not_sent', nil
        'Send DocuSeal Request (Default)'
      when 'sent', 'opened'
        days_since = application.document_signing_requested_at ? (Time.current - application.document_signing_requested_at) / 1.day : 0
        "Resend DocuSeal (#{days_since.round} days since sent)"
      when 'declined'
        'Resend DocuSeal (Provider Declined)'
      else
        'Send DocuSeal Request'
      end
    end

    def show_medical_certification_request_buttons?(application)
      application.medical_certification_status == 'not_requested' ||
        application.medical_certification_status == 'rejected' ||
        (application.medical_certification_status == 'requested' && !application.medical_certification.attached?)
    end

    def medical_certification_pending_review?(application)
      application.medical_certification.attached? &&
        (application.medical_certification_status_received? || application.medical_certification_status_requested?)
    end

    def show_secure_cert_upload_button?(application)
      !application.medical_certification_status_approved? &&
        !medical_certification_pending_review?(application)
    end

    def medical_certification_action_state(application, secure_request_forms: nil)
      latest_request = latest_medical_certification_notification(application, 'medical_certification_requested')
      latest_reject = latest_medical_certification_notification(application, 'medical_certification_rejected')
      active_secure_forms = Array(secure_request_forms || application.medical_provider_secure_request_forms).count(&:active?)

      MedicalCertificationActionState.new(
        latest_certification_request: latest_request,
        latest_certification_reject: latest_reject,
        requested_after_rejection: requested_after_rejection?(latest_request, latest_reject),
        provider_ready_for_docuseal: application.ready_for_docuseal?,
        docuseal_text: docuseal_button_text(application),
        secure_cert_upload_message: t('admin.applications.certification_upload_requests.create.provider_email_required'),
        active_secure_cert_upload_forms: active_secure_forms,
        docuseal_confirm: docuseal_confirmation(application, active_secure_forms),
        secure_cert_upload_confirm: secure_cert_upload_confirmation(application)
      )
    end

    private

    def latest_medical_certification_notification(application, action)
      Notification
        .where(notifiable: application, action: action)
        .order(created_at: :desc)
        .limit(1)
        .first
    end

    def requested_after_rejection?(latest_request, latest_reject)
      latest_request.present? &&
        latest_reject.present? &&
        latest_request.created_at > latest_reject.created_at
    end

    def docuseal_confirmation(application, active_secure_cert_upload_forms)
      if active_secure_cert_upload_forms.positive?
        if active_secure_cert_upload_forms == 1
          'A secure upload link is already active. Send DocuSeal as an additional option?'
        else
          "#{active_secure_cert_upload_forms} secure upload links are already active. Send DocuSeal as an additional option?"
        end
      else
        [
          "Send digital signing request to #{application.medical_provider_name}",
          "(#{application.medical_provider_email}) for #{application.constituent_full_name}'s disability certification?"
        ].join(' ')
      end
    end

    def secure_cert_upload_confirmation(application)
      if application.document_signing_status_sent? || application.document_signing_status_opened?
        "A DocuSeal request is already #{application.document_signing_status}. Send a secure upload link as an additional option?"
      else
        "Send secure certification upload link to #{application.medical_provider_email}?"
      end
    end

    def application_proof_history_address(application)
      [
        application.user&.physical_address_1,
        application.user&.physical_address_2,
        [application.user&.city, application.user&.state, application.user&.zip_code].compact.join(' ')
      ].compact_blank.join(' ').squish
    end
  end
end
