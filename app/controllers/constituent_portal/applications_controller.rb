# frozen_string_literal: true

module ConstituentPortal
  # Controller for handling constituent applications
  # Manages the full application lifecycle from creation to submission
  class ApplicationsController < ApplicationController
    # ParamCasting concern: Provides methods for safely casting boolean parameters
    # Key methods: cast_boolean_params, to_boolean, safe_boolean_cast
    # Flow: before_action cast_boolean_params -> converts checkbox values to proper booleans
    include ParamCasting
    # ApplicationFormHandling concern: Provides standardized form error handling and success messages
    # Key methods: render_form_errors, determine_success_message, initialize_address_and_provider_for_form
    # Flow: Handles form validation failures and success scenarios consistently
    include ApplicationFormHandling
    include DocumentUploadHandling
    include ApplicationDataStructures
    # AddressHelper concern: Provides standardized address creation and validation methods
    # Key methods: address_from_user, address_from_params, address_with_fallback, validate_address
    include AddressHelper
    # MedicalProviderHelper concern: Provides standardized medical provider creation and validation methods
    # Key methods: medical_provider_from_application, medical_provider_from_params, validate_medical_provider
    include MedicalProviderHelper

    # Custom exceptions for better error handling
    class UserAttributeUpdateError < StandardError; end
    class ApplicationCreationError < StandardError; end
    class DisabilityValidationError < StandardError; end

    before_action :authenticate_user!
    before_action :require_constituent!
    before_action :set_application, only: %i[show edit update]
    before_action :ensure_editable, only: %i[edit update]
    before_action :setup_address_for_form, only: %i[new edit]
    before_action :flag_pending_identity_review, only: %i[new edit]
    # ParamCasting concern: Automatically converts checkbox values to proper boolean types
    before_action :cast_boolean_params, only: %i[create update]
    before_action :set_paper_application_context, if: -> { Rails.env.test? }

    # Override current_user for tests
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
      # Initialize medical_provider_attributes with existing data for form fields
      # Use Struct for fixed set of known attributes so Rails fields_for can bind
      medical_provider_struct = Struct.new(:name, :phone, :fax, :email)
      @application.medical_provider_attributes = medical_provider_struct.new(
        @application.medical_provider_name,
        @application.medical_provider_phone,
        @application.medical_provider_fax,
        @application.medical_provider_email
      )
      # Set applicant user for form display (dependent if application is for dependent, otherwise current user)
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

    # Server-rendered FPL data helper methods
    # These inject threshold data into HTML data attributes for client-side validation
    # This is the Rails-idiomatic approach: data is rendered once on page load, avoiding
    # unnecessary AJAX requests for static configuration data.
    # See: app/services/income_threshold_calculation_service.rb for core FPL logic
    helper_method :fpl_thresholds_json, :fpl_modifier_value

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
      @applicant_user = current_user # Default to current user for self applications
    end

    def setup_applicant_context
      @applicant_type = determine_applicant_type
      @selected_dependent_id = params[:user_id].presence
      @selected_dependent_name = find_selected_dependent_name

      # Setup dependent application if needed
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
      @applicant_user = dependent # Set for use in view to display correct disability flags
    end

    def for_dependent_application?
      ['false', false].include?(params[:for_self])
    end

    def should_setup_dependent_application?
      params[:user_id].present? || for_dependent_application?
    end

    def setup_address_for_form
      # AddressHelper concern: Uses standardized address creation from user data
      # Flow: address_from_user(user) -> creates ApplicationDataStructures::Address object
      applicant = address_applicant_user
      # Prefer whatever address was just submitted, falling back to the applicant's stored address.
      # These fields render from this @address local rather than from @application, and they are
      # deliberately excluded from filtered_application_params because they belong to the user --
      # so without this a refused submission silently reverted the constituent's address edits. On
      # a GET there are no address params, which makes this identical to the previous behavior.
      @address = address_with_fallback(params[:application] || {}, applicant)
      @guardian_address = address_from_user(current_user) if applicant != current_user
      @use_guardian_address = applicant != current_user && applicant.physical_address_1.blank? && current_user.physical_address_1.present?
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

    # Application existence checks (memoized for performance)
    # Determines the target user ID (self or dependent) for application operations
    def target_user_id
      @target_user_id ||= params[:user_id].presence&.to_i || current_user.id
    end

    # Finds existing draft application for target user
    # For dependent applications, only finds drafts managed by current guardian
    def existing_draft
      @existing_draft ||= begin
        scope = Application.draft_for_constituent(target_user_id)
        # If this is for a dependent (user_id param present and != current_user),
        # only look for applications managed by current user
        scope = scope.where(managing_guardian_id: current_user.id) if params[:user_id].present? && target_user_id != current_user.id
        scope.first
      end
    end

    # Finds existing active (non-draft) application for target user
    # For dependent applications, only finds active apps managed by current guardian
    def existing_active_application
      @existing_active_application ||= begin
        scope = Application.active_for_constituent(target_user_id)
        # If this is for a dependent (user_id param present and != current_user),
        # only look for applications managed by current user
        scope = scope.where(managing_guardian_id: current_user.id) if params[:user_id].present? && target_user_id != current_user.id
        scope.first
      end
    end

    # Check and redirect if existing application (draft or active) exists
    # Returns true if redirected, false otherwise
    def redirect_to_existing_application
      # Priority 1: Redirect to edit if draft exists (user has unfinished work)
      if existing_draft
        user_name = existing_draft.user.full_name
        redirect_with_notice(
          edit_constituent_portal_application_path(existing_draft),
          "Continuing your draft application for #{user_name}"
        )
        return true
      end

      # Priority 2: Block if active application exists (already submitted/processing)
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
      # ApplicationCreator refuses several conditions before the application is ever populated --
      # pending identity review, sibling eligibility, participant requalification -- and its
      # failure result carries ApplicationForm#target_application, which for a new application is a
      # bare Application.new. That is always truthy, so the fallback above never fires and the form
      # would re-render empty, silently discarding everything the constituent typed. Re-apply the
      # submitted values so a refusal costs them an explanation, not their work.
      @application.assign_attributes(filtered_application_params) if @application.new_record?
      setup_address_for_form
      restore_medical_provider_from_params
      apply_failure_messages(result)

      # ApplicationFormHandling concern: Handles form validation errors consistently
      # Flow: render_form_errors -> adds errors to application + calls initialize_address_and_provider_for_form + renders with proper status
      render_form_errors(nil, @application)
    end

    def handle_update_failure(result)
      @application = result.application
      # Mirror image of the new-application case above. Here the returned application is the real
      # persisted draft, and a refusal raised before the application was populated leaves it
      # holding stored values -- so the form would re-render the *old* contents and silently
      # discard the constituent's latest edits. Re-applying the submitted values keeps the form
      # showing what they just typed; nothing is saved, this object is only rendered.
      @application.assign_attributes(filtered_application_params)
      apply_failure_messages(result)

      # setup_address_for_form is a before_action for :new and :edit only, so on the update path
      # @address is nil and rendering :edit raises inside _address_fields. Every ApplicationCreator
      # refusal on update hits that -- rebuild the form state the template needs before rendering.
      setup_address_for_form
      restore_medical_provider_from_params
      prepare_medical_provider_for_edit
      render :edit, status: :unprocessable_content
    end

    # A pending-review refusal is not a validation error: the constituent did nothing wrong and
    # their draft is intact. The views render it as an informational notice instead of listing it
    # among errors, so this exposes the reason as typed state rather than making the view match on
    # message text.
    # The certifying-professional fields bind to @application.medical_provider_attributes. On a
    # refusal that attribute holds either nothing (create) or stored values (update), so without
    # this the constituent's freshly typed provider details are dropped -- and because they are
    # required for submission, the retry then fails validation instead of repeating the original
    # refusal. Note the submitted shape is application[medical_provider_attributes][...], which
    # find_param_value does not look for. Deliberate blanks are preserved as blanks.
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
        # Rendered as a notice, deliberately not added to the error list: adding it would produce a
        # red "N errors prohibited this application from being saved" block that is wrong on every
        # count -- nothing is wrong with the application, nothing failed to save, and the
        # constituent did nothing incorrect.
        @pending_identity_review_message = result.error_messages.first
        locale = pending_review_locale(address_applicant_user)
        @submission_blocked_message = submission_gate_blocked_message(locale)
        # Only on this path. The GET notice fires before anything is selected, so there is nothing
        # to have lost; here the constituent did select documents and the re-render cannot give
        # them back.
        @pending_identity_review_documents_message = I18n.t(
          'applications.submission_gate.refused_documents_notice', locale: locale
        )
        return
      end

      result.error_messages.each { |message| @application.errors.add(:base, message) }
    end

    # Asked on GET so the form can say so before the constituent starts work. Without this the only
    # signal arrives on the refusal -- after they have selected their income and residency
    # documents, which the re-render cannot repopulate because no browser lets a server set the
    # value of a file input. They would have to find and choose those files again for a submission
    # that is going to be refused identically until staff resolve the case.
    #
    # This read takes no lock and is deliberately advisory. Applications::ApplicationCreator asks
    # the same question under lock and is what actually decides; a case that opens or resolves
    # between this GET and the submit is handled there.
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

    def submission_gate_blocked_message(locale)
      I18n.t('applications.submission_gate.pending_identity_review_status', locale: locale)
    end

    # No submitted locale to prefer on a GET, so this is ApplicationForm#message_locale minus its
    # first candidate: the applicant's effective locale, then the actor's, then the default.
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
      # ApplicationFormHandling concern: Standardizes success message determination
      # Flow: determine_success_message(application, is_submission) -> returns appropriate message
      # is_submission = true when status changed to in_progress, false for draft saves
      determine_success_message(application, is_submission: application.status != original_status && application.status_in_progress?)
    end

    def prepare_medical_provider_for_edit
      # MedicalProviderHelper concern: Uses standardized medical provider creation from application data
      # Flow: medical_provider_from_application(app) -> creates ApplicationDataStructures::MedicalProviderInfo object
      @medical_provider = medical_provider_from_application(@application)
    end

    def render_autosave_response(result)
      if result[:success]
        render json: {
          success: true,
          applicationId: result[:application_id],
          message: result[:message]
        }, status: :ok
      else
        render json: { success: false, errors: result[:errors] }, status: :unprocessable_content
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
      # MedicalProviderHelper concern: Uses standardized medical provider creation from parameters
      # Flow: medical_provider_from_params(params) -> creates ApplicationDataStructures::MedicalProviderInfo object
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
      # Use model scope for Rails-centric query building
      Application.accessible_by(current_user).find_by(id: params[:id])
    end

    def find_application_by_flexible_query
      # Fallback: check if application exists and is accessible
      app = Application.find_by(id: params[:id])
      app&.accessible_by?(current_user) ? app : nil
    end

    def handle_application_not_found
      log_error("Application #{params[:id]} not found for user #{current_user.id}")
      redirect_to constituent_portal_dashboard_path, alert: 'Application not found'
    end

    def ensure_editable
      # Check if application status allows editing
      unless @application.status_draft?
        redirect_to constituent_portal_application_path(@application),
                    alert: 'This application has already been submitted and cannot be edited.'
        return
      end

      # Use model's authorization method (Rails-centric approach)
      return if @application.editable_by?(current_user)

      # Provide specific feedback based on the situation
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
      # AddressHelper concern: Uses standardized address creation with fallback logic
      # Flow: address_with_fallback(params, user) -> creates Address object with param values falling back to user values
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
