# frozen_string_literal: true

module Admin
  module ApplicationsHelper
    include RejectionReasonsHelper

    def practitioner_assignment_option_label(practitioner)
      identifier = practitioner.email.presence || "ID ##{practitioner.id}"
      "#{practitioner.full_name} (#{identifier})"
    end

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

      url = document_download_path(application.medical_certification, disposition: :inline)

      link_to 'View Medical Certification Document', url,
              target: '_blank',
              class: style == :button ? 'btn btn-primary' : 'text-primary-700 hover:text-primary-900 underline',
              rel: 'noopener'
    end

    def medical_certification_submission_method(application)
      return 'unknown' unless application.medical_certification.attached?

      if application.respond_to?(:medical_certification_submission_method) &&
         application.medical_certification_submission_method.present?
        return application.medical_certification_submission_method
      end

      status_change = ApplicationStatusChange.where(application_id: application.id)
                                             .where("metadata->>'change_type' = ? OR to_status = ?",
                                                    'medical_certification', 'received')
                                             .order(created_at: :desc)
                                             .first

      if status_change&.metadata.present? &&
         status_change.metadata['submission_method'].present?
        return status_change.metadata['submission_method']
      end

      'portal'
    end

    ADDITIONAL_CERTIFICATION_REVIEW_NOTES = {
      'certification_approved' => 'received after approval, review',
      'certification_received' => 'received while another certification awaited review, review',
      'request_predates_rejection' => 'requested before the latest rejection, review'
    }.freeze

    def additional_medical_certification_source_label(certification)
      source = case certification.blob.metadata['source']
               when 'docuseal' then 'DocuSeal signed form'
               when 'secure_form' then 'Secure upload'
               else 'Additional certification'
               end
      note = ADDITIONAL_CERTIFICATION_REVIEW_NOTES[certification.blob.metadata['retention_reason']]
      note ? "#{source} (#{note})" : source
    end

    def voucher_assignment_detail(metadata, fallback_time:)
      issued_at = if metadata['issued_at'].present?
                    Time.zone.parse(metadata['issued_at'])
                  else
                    fallback_time
                  end
      issued_date = issued_at.strftime('%B %d, %Y')
      voucher_text = "Voucher #{metadata['voucher_code']}"
      value_text = "for #{number_to_currency(metadata['initial_value'])}"

      case metadata['assignment_method']
      when 'automatic'
        "#{voucher_text} automatically issued on #{issued_date} #{value_text}"
      when 'manual_approval'
        "#{voucher_text} issued after admin approval on #{issued_date} #{value_text}"
      else
        "#{voucher_text} assigned on #{issued_date} #{value_text}"
      end
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

    def toggle_direction(column)
      params[:sort] == column.to_s && params[:direction] == 'asc' ? 'desc' : 'asc'
    end

    # Proof activity for one proof type, oldest first, with duplicate submissions removed.
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
      return false if application.medical_certification_status_approved?
      return true if application.medical_certification_status_rejected?

      !application.medical_certification.attached?
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
