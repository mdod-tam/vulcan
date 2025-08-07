# frozen_string_literal: true

# Controller for handling proof submissions from constituents through the portal
#
# This controller handles the constituent-facing proof submission workflow:
# 1. Initial proof upload setup
# 2. Direct upload for client-side uploading to S3
# 3. Proof resubmission (after rejection)
#
# Note: This controller handles the UI and workflow for proof submission, and
# the actual attachment is delegated to ProofAttachmentService to maintain
# consistency with the paper application submission path. Both constituent portal
# and paper submissions use ProofAttachmentService as the single source of truth for proof attachments.
module ConstituentPortal
  module Proofs
    class ProofsController < ApplicationController
      include RequestMetadataHelper

      # Tell Rails to look for views in the new location
      prepend_view_path 'app/views/constituent_portal/proofs'
      before_action :authenticate_user!
      before_action :require_constituent!
      before_action :set_application
      before_action :ensure_can_submit_proof, only: %i[new resubmit]
      before_action :authorize_proof_access!, only: %i[resubmit]
      before_action :check_rate_limit, only: %i[resubmit]
      skip_before_action :verify_authenticity_token, only: [:direct_upload]

      def new
        @proof_type = params[:proof_type]
        authorize_proof_access!
      end

      def direct_upload
        # Use keyword arguments for create_before_direct_upload! (Rails 6.1+)
        blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_params.to_h.symbolize_keys)
        render json: direct_upload_json(blob)
      rescue ActionController::ParameterMissing => e
        render json: { error: e.message }, status: :unprocessable_content
      end

      def resubmit
        # The before_action has already run authorize_proof_access!
        # Return if it fails to prevent a double render error
        return if performed?

        # ProofAttachmentService manages its own transactions (we don't need an outer transaction)
        # This prevents nested transaction issues that can cause attachment rollbacks
        attach_and_update_proof
        track_submission
        handle_successful_submission
      rescue RateLimit::ExceededError
        handle_rate_limit_error
      rescue StandardError => e
        handle_submission_error(e)
        raise
      end

      private

      def blob_params
        params.expect(blob: [:filename, :byte_size, :checksum, :content_type, { metadata: {} }])
      end

      def direct_upload_json(blob)
        {
          signed_id: blob.signed_id,
          direct_upload: {
            url: blob.service_url_for_direct_upload,
            headers: blob.service_headers_for_direct_upload
          }
        }
      end

      def set_application
        application_id = extract_application_id
        return if redirect_if_missing_application_id(application_id)

        @application = find_user_application(application_id)
        handle_application_not_found(application_id) if @application.nil?
      end

      def extract_application_id
        # The application ID could be in different params based on the routing
        # In routes.rb: get 'proofs/new/:proof_type', to: 'proofs/proofs#new', as: :new_proof
        # The :id is from the resource-level param; extract the ID from the URL path
        application_id = params[:application_id]

        # Special handling for the route format
        if application_id.nil? && params[:id].present?
          # When using routes like /constituent_portal/applications/123/proofs/new/income; the ID comes through as :id
          application_id = params[:id]
        end

        application_id
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
        # First try the standard approach
        application = current_user.applications.find_by(id: application_id)

        # If that fails, try a more flexible query to handle potential type mismatches
        return application unless application.nil?

        Application.where(id: application_id)
                   .where(user_id: current_user.id)
                   .first
      end

      def handle_application_not_found(application_id)
        Rails.logger.error "Application not found with ID: #{application_id} for user: #{current_user.id}"
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
        nil # Explicit return to prevent code execution after redirect
      end

      def authorize_proof_access!
        return if valid_proof_type? && can_modify_proof?

        redirect_to constituent_portal_application_path(@application),
                    alert: 'Invalid proof type or status'
        false # Explicit return to halt execution
      end

      def check_rate_limit
        RateLimit.check!(:proof_submission, current_user.id)
      rescue RateLimit::ExceededError
        # Set flash and keep it through redirects
        flash[:alert] = 'Please wait before submitting another proof'
        flash.keep(:alert)
        redirect_to constituent_portal_application_path(@application)
        false
      end

      # Delegates the actual proof attachment to ProofAttachmentService
      # This ensures a consistent approach to attachment across the application
      # Both constituent portal and paper applications use the same service
      def attach_and_update_proof
        is_resubmitting = determine_resubmission_status
        log_resubmission_attempt(is_resubmitting)

        # Set Current attribute to communicate resubmission status to validation layer
        Current.resubmitting_proof = is_resubmitting

        begin
          result = ProofAttachmentService.attach_proof(build_attachment_params(is_resubmitting))
        ensure
          # Always reset Current attribute, even if an exception occurs
          Current.resubmitting_proof = nil
        end

        return if result[:success]

        Rails.logger.error "Failed to attach proof: #{result[:error]&.message}"
        raise "Failed to attach proof: #{result[:error]&.message}"
      end

      def determine_resubmission_status
        (@application.income_proof_status_rejected? && params[:proof_type] == 'income') ||
          (@application.residency_proof_status_rejected? && params[:proof_type] == 'residency')
      end

      def log_resubmission_attempt(is_resubmitting)
        return unless is_resubmitting

        Rails.logger.info "Resubmitting previously rejected #{params[:proof_type]} proof for application #{@application.id}"
      end

      def build_attachment_params(is_resubmitting)
        {
          application: @application,
          proof_type: params[:proof_type],
          blob_or_file: params[:"#{params[:proof_type]}_proof_upload"],
          status: :not_reviewed,
          admin: current_user,
          submission_method: :web,
          # Using RequestMetadataHelper for consistent metadata creation
          metadata: proof_submission_metadata(params[:proof_type], {
                                                resubmitting: is_resubmitting # Pass resubmission flag in metadata
                                              })
        }
      end

      def handle_successful_submission
        # Set flash and keep it through redirects
        flash[:notice] = 'Proof submitted successfully'
        flash.keep(:notice)
        redirect_to constituent_portal_application_path(@application)
      end

      def handle_rate_limit_error
        # Set flash and keep it through redirects
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
        # Create Event for application audit log
        AuditEventService.log(
          action: 'proof_submitted',
          actor: current_user,
          auditable: @application,
          # Using RequestMetadataHelper for consistent audit metadata
          metadata: audit_metadata({
                                     proof_type: params[:proof_type],
                                     submission_method: 'web'
                                   })
        )
      end

      def valid_proof_type?
        %w[income residency].include?(params[:proof_type])
      end

      def can_modify_proof?
        case params[:proof_type]
        when 'income'
          @application.rejected_income_proof?
        when 'residency'
          @application.rejected_residency_proof?
        end
      end
    end
  end
end
