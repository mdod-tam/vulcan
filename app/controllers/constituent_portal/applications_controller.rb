# frozen_string_literal: true

module ConstituentPortal
  class ApplicationsController < ApplicationController
    include ParamCasting
    include ApplicationFormHandling
    include ApplicationDataStructures
    include AddressHelper
    include MedicalProviderHelper

    class UserAttributeUpdateError < StandardError; end
    class ApplicationCreationError < StandardError; end
    class DisabilityValidationError < StandardError; end

    before_action :authenticate_user!
    before_action :require_constituent!
    before_action :set_application, only: %i[show edit update]
    before_action :ensure_editable, only: %i[edit update]
    before_action :setup_address_for_form, only: %i[new edit]
    before_action :flag_pending_identity_review, only: %i[new edit]
    before_action :cast_boolean_params, only: %i[create update]
    before_action :set_paper_application_context, if: -> { Rails.env.test? }

    # Test identity can come from ENV or Current instead of the session.
    def current_user
      if Rails.env.test? && (ENV['TEST_USER_ID'].present? || Current.test_user_id.present?)
        test_user_id = ENV['TEST_USER_ID'] || Current.test_user_id
        @current_user ||= User.find_by(id: test_user_id)
        return @current_user if @current_user
      end
      super
    end

    def index
      @applications = current_user.applications.order(created_at: :desc)
    end

    def show
      @certification_requests = Notification.where(
        notifiable: @application,
        action: 'medical_certification_requested'
      ).order(created_at: :desc)
    end

    def new
      return if redirect_to_existing_application

      initialize_new_application
      setup_applicant_context
      setup_form_dependencies
    end

    def edit
      # A Struct gives fields_for named provider attributes.
      medical_provider_struct = Struct.new(:name, :phone, :fax, :email)
      @application.medical_provider_attributes = medical_provider_struct.new(
        @application.medical_provider_name,
        @application.medical_provider_phone,
        @application.medical_provider_fax,
        @application.medical_provider_email
      )
      @applicant_user = @application.for_dependent? ? @application.user : current_user
    end

    def create
      @form = build_application_form

      unless @form.valid?
        show_missing_provider_info_flash(@form)
        return render_form_errors(@form)
      end

      result = Applications::ApplicationCreator.call(@form)

      if result.success?
        handle_creation_success(result)
      else
        handle_creation_failure(result)
      end
    rescue StandardError => e
      Rails.logger.error "Error creating application: #{e.message}"
      @application = result&.application || Application.new(filtered_application_params)
      @application.errors.add(:base, e.message)
      render_form_errors(nil, @application)
    end

    def update
      original_status = @application.status

      @form = ApplicationForm.new(
        current_user: current_user,
        application: @application,
        params: params
      )

      unless @form.valid?
        show_missing_provider_info_flash(@form)
        return render_form_errors(@form, @application)
      end

      result = Applications::ApplicationCreator.call(@form)

      if result.success?
        notice = determine_update_notice(original_status, result.application)

        respond_to do |format|
          format.html { redirect_to constituent_portal_application_path(result.application), notice: notice }
          format.turbo_stream do
            flash[:notice] = notice
            redirect_to constituent_portal_application_path(result.application, format: :html)
          end
        end
      else
        handle_update_failure(result)
      end
    end

    def resubmit_proof
      @application = current_user.applications.find(params[:id])
      if @application.resubmit_proof!
        redirect_with_notice(constituent_portal_application_path(@application),
                             'Proof resubmitted successfully')
      else
        redirect_with_alert(constituent_portal_application_path(@application),
                            'Failed to resubmit proof')
      end
    end

    def request_training
      @application = current_user.applications.find(params[:id])

      result = Applications::TrainingRequestService.new(
        application: @application,
        current_user: current_user
      ).call

      if result.success?
        redirect_with_notice(constituent_portal_dashboard_path, result.message)
      else
        redirect_with_alert(constituent_portal_dashboard_path, result.message)
      end
    end

    def autosave_field
      result = Applications::AutosaveService.new(
        current_user: current_user,
        params: params
      ).call

      render_autosave_response(result)
    rescue ActiveRecord::RecordNotFound
      render_autosave_error('Application not found', :not_found)
    rescue StandardError => e
      log_error("Autosave error: #{e.message}", e)
      render_autosave_error('An error occurred during autosave', :internal_server_error)
    end

    # Render FPL thresholds in data attributes so client validation needs no configuration request.
    # See: app/services/income_threshold_calculation_service.rb
    helper_method :fpl_thresholds_json, :fpl_modifier_value, :form_message_locale, :autosave_form_state

    def fpl_thresholds_json
      return '{}' unless FeatureFlag.income_proof_required?

      thresholds = (1..8).to_h do |size|
        result = IncomeThresholdCalculationService.call(size)
        if result.success?
          [size.to_s, result.data[:base_fpl]]
        else
          [size.to_s, 0]
        end
      end
      thresholds.to_json
    end

    def fpl_modifier_value
      return 0 unless FeatureFlag.income_proof_required?

      result = IncomeThresholdCalculationService.call(1)
      if result.success?
        result.data[:modifier]
      else
        400
      end
    end

    private

    def initialize_new_application
      @application = current_user.applications.new
      @application.medical_provider_attributes ||= {}
      @applicant_user = current_user
    end

    def setup_applicant_context
      @applicant_type = determine_applicant_type
      @selected_dependent_id = params[:user_id].presence
      @selected_dependent_name = find_selected_dependent_name

      setup_dependent_application if should_setup_dependent_application?
    end

    def setup_form_dependencies
      setup_address_for_form
      @dependents = current_user.dependents.order(:first_name, :last_name)
    end

    def determine_applicant_type
      if params[:for_self] == 'false' || params[:user_id].present?
        'dependent'
      else
        'self'
      end
    end

    def find_selected_dependent_name
      return nil if @selected_dependent_id.blank?

      dependent = current_user.dependents.find_by(id: @selected_dependent_id)
      dependent&.full_name
    end

    def build_application_form
      ApplicationForm.new(
        current_user: current_user,
        params: params
      )
    end

    def handle_creation_success(result)
      notice = determine_creation_notice
      redirect_to_application_with_notice(result.application, notice)
    end

    def determine_creation_notice
      params[:submit_application] ? 'Application submitted successfully!' : 'Application saved as draft.'
    end

    def redirect_to_application_with_notice(application, notice)
      respond_to do |format|
        format.html { redirect_to constituent_portal_application_path(application), notice: notice }
        format.turbo_stream do
          flash[:notice] = notice
          redirect_to constituent_portal_application_path(application, format: :html)
        end
      end
    end

    def setup_dependent_application
      return if params[:user_id].blank?

      setup_specific_dependent_application
    end

    def setup_specific_dependent_application
      dependent = current_user.dependents.find_by(id: params[:user_id])
      return unless dependent

      @application.user = dependent
      @application.user_id = dependent.id
      @application.managing_guardian_id = current_user.id
      @applicant_user = dependent
    end

    def for_dependent_application?
      ['false', false].include?(params[:for_self])
    end

    def should_setup_dependent_application?
      params[:user_id].present? || for_dependent_application?
    end

    def setup_address_for_form
      applicant = address_applicant_user
      # Address fields bind to @address and belong to the applicant user, not Application.
      # Submitted values take precedence so a refusal preserves address edits.
      @address = address_with_fallback(params[:application] || {}, applicant)
      @guardian_address = address_from_user(current_user) if applicant != current_user
      @use_guardian_address = use_guardian_address_choice(applicant)
      @address = @guardian_address if @use_guardian_address && @guardian_address.present?
    end

    def address_applicant_user
      return @application.user if @application&.for_dependent?

      dependent_id = params[:user_id].presence || params.dig(:application, :user_id).presence

      if dependent_id.present?
        current_user.dependents.find_by(id: dependent_id) || current_user
      else
        current_user
      end
    end

    def target_user_id
      @target_user_id ||= params[:user_id].presence&.to_i || current_user.id
    end

    def existing_draft
      @existing_draft ||= Application.resumable_portal_draft(
        Application.draft_for_constituent(target_user_id), actor_id: current_user.id
      )
    end

    # A dependent lookup restricts active applications to the acting guardian.
    def existing_active_application
      @existing_active_application ||= begin
        scope = Application.active_for_constituent(target_user_id)
        scope = scope.where(managing_guardian_id: current_user.id) if params[:user_id].present? && target_user_id != current_user.id
        scope.first
      end
    end

    # A draft takes precedence over an active application. A redirect returns true.
    # Without either application, the method returns false.
    def redirect_to_existing_application
      if existing_draft
        user_name = existing_draft.user.full_name
        redirect_with_notice(
          edit_constituent_portal_application_path(existing_draft),
          "Continuing your draft application for #{user_name}"
        )
        return true
      end

      if existing_active_application
        user_name = existing_active_application.user.full_name
        redirect_with_alert(
          constituent_portal_application_path(existing_active_application),
          "#{user_name} already has an active application. Please wait for this application to be processed."
        )
        return true
      end

      false
    end

    def handle_creation_failure(result)
      @application = result.application || Application.new(filtered_application_params)
      # Early refusals return an unpopulated application or a resumed draft with stored values.
      # Restore submitted values in memory for the form without saving them.
      @application.assign_attributes(filtered_application_params)
      restore_applicant_context_from_params
      setup_address_for_form
      restore_medical_provider_from_params
      apply_failure_messages(result)

      render_form_errors(nil, @application)
    end

    def handle_update_failure(result)
      @application = result.application
      # An early refusal can return stored draft values. Restore the latest edits in memory without saving them.
      @application.assign_attributes(filtered_application_params)
      apply_failure_messages(result)

      # The address before_action runs on GET only. Rebuild the form dependencies before the update refusal renders.
      setup_address_for_form
      restore_medical_provider_from_params
      prepare_medical_provider_for_edit
      render :edit, status: :unprocessable_content
    end

    # A submitted guardian-address choice takes precedence so a refusal preserves the selected address.
    # When the parameter is absent, infer the choice from stored addresses.
    def use_guardian_address_choice(applicant)
      return false if applicant == current_user

      submitted = params.dig(:application, :use_guardian_address)
      return ActiveModel::Type::Boolean.new.cast(submitted) unless submitted.nil?

      applicant.physical_address_1.blank? && current_user.physical_address_1.present?
    end

    # The new-form link supplies user_id at the top level. POST supplies application[user_id].
    # Resolve the posted id through current_user.dependents to preserve the applicant on refusal.
    # If the id does not resolve, the form renders the self-applicant branch.
    def restore_applicant_context_from_params
      submitted_id = params.dig(:application, :user_id).presence || params[:user_id].presence
      dependent = current_user.dependents.find_by(id: submitted_id) if submitted_id.present?

      if dependent.nil?
        @applicant_type = 'self'
        return
      end

      @applicant_type = 'dependent'
      @selected_dependent_id = dependent.id
      @selected_dependent_name = dependent.full_name
      @applicant_user = dependent
      @application.user_id = dependent.id
      @application.managing_guardian_id = current_user.id
    end

    # fields_for binds to medical_provider_attributes. find_param_value does not read this nested parameter shape.
    # Restore the submitted provider values, including blanks, for a retry.
    def restore_medical_provider_from_params
      submitted = params.dig(:application, :medical_provider_attributes)
      return if submitted.blank?

      provider_struct = Struct.new(:name, :phone, :fax, :email)
      @application.medical_provider_attributes = provider_struct.new(
        submitted[:name], submitted[:phone], submitted[:fax], submitted[:email]
      )
    end

    def apply_failure_messages(result)
      if result.pending_identity_review?
        # Staff review is an informational refusal, not an application validation error.
        @pending_identity_review_message = result.error_messages.first
        # Match the refusal locale, including a new submitted preference, across all notices.
        locale = form_message_locale
        @submission_blocked_message = submission_gate_blocked_message(locale)
        # Show file-selection recovery advice only after a refusal, not on GET.
        @pending_identity_review_documents_message = I18n.t(
          'applications.submission_gate.refused_documents_notice', locale: locale
        )
        return
      end

      result.error_messages.each { |message| @application.errors.add(:base, message) }
    end

    # Warn on GET before file selection because a refusal cannot restore file input values.
    # This unlocked read is advisory. ApplicationCreator enforces the rule under lock at submission.
    def flag_pending_identity_review
      applicant = address_applicant_user
      return unless Application.identity_review_pending_for?(applicant)

      locale = pending_review_locale(applicant)
      @pending_identity_review_message = I18n.t(
        'activemodel.errors.models.application_form.attributes.base.pending_identity_review',
        locale: locale
      )
      @submission_blocked_message = submission_gate_blocked_message(locale)
    end

    # Form messages use the submitted preference when supported, then applicant, actor, and default locales.
    def form_message_locale
      @form&.message_locale || pending_review_locale(address_applicant_user)
    end

    def autosave_form_state
      Applications::AutosaveRevisions.new(@application).form_state(context: params[:autosave_context], revision: params[:autosave_revision])
    end

    def submission_gate_blocked_message(locale)
      I18n.t('applications.submission_gate.pending_identity_review_status', locale: locale)
    end

    # GET has no form-owned submitted preference, so use applicant, actor, then default locale.
    def pending_review_locale(applicant)
      applicant&.effective_message_locale ||
        current_user&.effective_message_locale ||
        I18n.default_locale
    end

    def show_missing_provider_info_flash(form)
      return unless form.errors.added?(:base, :medical_provider_required)

      flash.now[:alert] = I18n.t(
        'activemodel.errors.models.application_form.attributes.base.medical_provider_required',
        locale: form.message_locale
      )
    end

    def determine_update_notice(original_status, application)
      determine_success_message(application, is_submission: application.status != original_status && application.status_in_progress?)
    end

    def prepare_medical_provider_for_edit
      @medical_provider = medical_provider_from_application(@application)
    end

    def render_autosave_response(result)
      if result[:success]
        render json: {
          success: true,
          applicationId: result[:application_id],
          outcome: result[:outcome],
          revision: result[:revision],
          current_revision: result[:current_revision],
          value: result[:value]
        }, status: :ok
      else
        render json: { success: false, errors: result[:errors], status_message: result[:status_message] }.compact, status: :unprocessable_content
      end
    end

    def render_autosave_error(message, status)
      render json: { success: false, errors: { base: [message] } }, status: status
    end

    def redirect_to_app(app)
      notice = params[:submit_application] ? 'Application submitted successfully!' : 'Application saved as draft.'
      redirect_to constituent_portal_application_path(app), notice: notice
    end

    def build_medical_provider_for_form
      @application.medical_provider_attributes ||= {} if @application
      provider_params = {
        medical_provider_name: find_param_value(:name, :medical_provider),
        medical_provider_phone: find_param_value(:phone, :medical_provider),
        medical_provider_fax: find_param_value(:fax, :medical_provider),
        medical_provider_email: find_param_value(:email, :medical_provider)
      }
      @medical_provider = medical_provider_from_params(provider_params)
    end

    def find_param_value(field, param_type)
      params.dig(param_type, field) ||
        params.dig(:application, param_type, field) ||
        params.dig(:application, :"#{param_type}_#{field}") ||
        @application&.send("#{param_type}_#{field}")
    end

    def filtered_application_params
      application_params.except(
        :medical_provider_attributes,
        # This checkbox controls form state. Application has no use_guardian_address attribute.
        :use_guardian_address,
        :hearing_disability,
        :vision_disability,
        :speech_disability,
        :mobility_disability,
        :cognition_disability,
        :physical_address_1,
        :physical_address_2,
        :city,
        :state,
        :zip_code
      )
    end

    def set_application
      @application = find_application_by_standard_query
      @application = find_application_by_flexible_query if @application.nil?
      handle_application_not_found if @application.nil?
    end

    def find_application_by_standard_query
      Application.accessible_by(current_user).find_by(id: params[:id])
    end

    def find_application_by_flexible_query
      app = Application.find_by(id: params[:id])
      app&.accessible_by?(current_user) ? app : nil
    end

    def handle_application_not_found
      log_error("Application #{params[:id]} not found for user #{current_user.id}")
      redirect_to constituent_portal_dashboard_path, alert: 'Application not found'
    end

    def ensure_editable
      unless @application.status_draft?
        redirect_to constituent_portal_application_path(@application),
                    alert: 'This application has already been submitted and cannot be edited.'
        return
      end

      return if @application.editable_by?(current_user)

      if @application.for_dependent?
        redirect_to constituent_portal_application_path(@application),
                    alert: 'This application is managed by a guardian. Only the managing guardian can edit it.'
      else
        redirect_to constituent_portal_application_path(@application),
                    alert: 'You do not have permission to edit this application.'
      end
    end

    def application_params
      params.expect(
        application: %i[
          annual_income household_size maryland_resident self_certify_disability terms_accepted information_verified medical_release_authorized
          medical_provider_name medical_provider_phone medical_provider_fax medical_provider_email
          physical_address_1 physical_address_2 city state zip_code
          use_guardian_address
          hearing_disability vision_disability speech_disability mobility_disability cognition_disability
          alternate_contact_name alternate_contact_phone alternate_contact_email alternate_contact_relationship_type
          medical_provider_attributes
        ]
      )
    end

    def require_constituent!
      return if current_user&.constituent?

      redirect_to root_path, alert: 'Access denied'
    end

    def initialize_address
      application_params = params[:application] || {}
      applicant = address_applicant_user
      @address = address_with_fallback(application_params, applicant)
      @guardian_address = address_from_user(current_user) if applicant != current_user
      @use_guardian_address = ActiveModel::Type::Boolean.new.cast(params[:use_guardian_address] || application_params[:use_guardian_address])
      @address = @guardian_address if @use_guardian_address && @guardian_address.present?
    end

    def set_paper_application_context
      Current.paper_context = true
    end
  end
end
