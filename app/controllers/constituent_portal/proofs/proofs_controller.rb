# frozen_string_literal: true

# Lets a constituent replace a rejected proof. The form uploads the file directly to storage on submit.
# ProofAttachmentService attaches the proof, as it does for paper intake.
module ConstituentPortal
  module Proofs
    class ProofsController < ApplicationController
      include RequestMetadataHelper

      before_action :authenticate_user!
      before_action :require_constituent!
      before_action :set_application
      before_action :ensure_can_submit_proof, only: %i[new resubmit]
      before_action :authorize_proof_access!, only: %i[resubmit]
      before_action :check_rate_limit, only: %i[resubmit]

      def new
        @proof_type = params[:proof_type]
        authorize_proof_access!
      end

      def resubmit
        # Do not add an outer transaction. ProofAttachmentService owns its transactions,
        # and nesting can roll back the attachment.
        attach_and_update_proof
        return if performed?

        track_submission
        handle_successful_submission
      rescue RateLimit::ExceededError
        handle_rate_limit_error
      rescue StandardError => e
        handle_submission_error(e)
        raise
      end

      private

      def set_application
        application_id = params[:application_id]
        return if redirect_if_missing_application_id(application_id)

        @application = find_user_application(application_id)
        handle_application_not_found(application_id) if @application.nil?
      end

      # rubocop:disable Naming/PredicateMethod
      def redirect_if_missing_application_id(application_id)
        return false if application_id.present?

        Rails.logger.error "Application ID is nil or empty in params: #{params.inspect}"
        redirect_to constituent_portal_dashboard_path, alert: 'Application not found'
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def find_user_application(application_id)
        application = current_user.applications.find_by(id: application_id)
        return application unless application.nil?

        # A guardian can also submit proof for a dependent application.
        dependent_ids = current_user.dependents.pluck(:id)
        return nil if dependent_ids.empty?

        Application.where(id: application_id)
                   .where(user_id: dependent_ids)
                   .first
      end

      def handle_application_not_found(application_id)
        Rails.logger.error "Application not found with ID: #{application_id} for user: #{current_user.id} with dependents: #{current_user.dependents.pluck(:id)}"
        redirect_to constituent_portal_dashboard_path, alert: 'Application not found'
      end

      def require_constituent!
        return if current_user&.constituent?

        redirect_to root_path, alert: 'Access denied'
      end

      def ensure_can_submit_proof
        return if @application.can_submit_proof?

        redirect_to constituent_portal_application_path(@application),
                    alert: 'Cannot submit proof at this time'
        nil
      end

      def authorize_proof_access!
        return if valid_proof_type? && can_modify_proof?

        redirect_to constituent_portal_application_path(@application),
                    alert: 'Invalid proof type or status'
        false
      end

      def check_rate_limit
        RateLimit.check!(:proof_submission, current_user.id)
      rescue RateLimit::ExceededError
        flash[:alert] = 'Please wait before submitting another proof'
        flash.keep(:alert)
        redirect_to constituent_portal_application_path(@application)
        false
      end

      def attach_and_update_proof
        is_resubmitting = determine_resubmission_status
        log_resubmission_attempt(is_resubmitting)

        result = ProofAttachmentService.attach_proof(build_attachment_params(is_resubmitting))

        return if result[:success]
        return render_refused_upload(result[:error]) if result[:error].is_a?(UploadedDocument::Refused)

        Rails.logger.error "Failed to attach proof: #{result[:error]&.message}"
        raise "Failed to attach proof: #{result[:error]&.message}"
      end

      # A refused upload changes nothing. Restore the form with the reason and any earlier usable upload.
      def render_refused_upload(refusal)
        @proof_type = params[:proof_type]
        @retained_upload = UploadedDocument.retained(params, record: @application, field: proof_field)
        flash.now[:alert] = refusal.user_message
        render :new, status: :unprocessable_content
      end

      def proof_field
        "#{params[:proof_type]}_proof"
      end

      def determine_resubmission_status
        (@application.income_proof_status_rejected? && params[:proof_type] == 'income') ||
          (@application.residency_proof_status_rejected? && params[:proof_type] == 'residency') ||
          (@application.id_proof_status_rejected? && params[:proof_type] == 'id')
      end

      def log_resubmission_attempt(is_resubmitting)
        return unless is_resubmitting

        Rails.logger.info "Resubmitting previously rejected #{params[:proof_type]} proof for application #{@application.id}"
      end

      def build_attachment_params(is_resubmitting)
        {
          application: @application,
          proof_type: params[:proof_type],
          blob_or_file: UploadedDocument.submitted(params, proof_field),
          status: :not_reviewed,
          admin: current_user,
          submission_method: :web,
          metadata: proof_submission_metadata(params[:proof_type], {
                                                resubmitting: is_resubmitting
                                              })
        }
      end

      def handle_successful_submission
        flash[:notice] = 'Proof submitted successfully'
        flash.keep(:notice)
        redirect_to constituent_portal_application_path(@application)
      end

      def handle_rate_limit_error
        flash[:alert] = 'Please wait before submitting another proof'
        flash.keep(:alert)
        redirect_to constituent_portal_application_path(@application)
      end

      def handle_submission_error(error)
        return if Rails.env.test?

        Rails.logger.error "ERROR IN RESUBMIT: #{error.class.name}: #{error.message}"
        Rails.logger.error error.backtrace.join("\n")
      end

      def track_submission
        AuditEventService.log(
          action: 'proof_submitted',
          actor: current_user,
          auditable: @application,
          metadata: audit_metadata({
                                     proof_type: params[:proof_type],
                                     submission_method: 'web'
                                   })
        )
      end

      def valid_proof_type?
        %w[income residency id].include?(params[:proof_type])
      end

      def can_modify_proof?
        @application.proof_resubmittable_via_portal?(params[:proof_type])
      end
    end
  end
end
