# frozen_string_literal: true

module ConstituentPortal
  class DependentsController < ApplicationController
    include UserServiceIntegration

    before_action :authenticate_user!
    before_action :require_constituent!
    before_action :set_current_user
    before_action :set_dependent, only: %i[show edit update destroy]

    # The form key identifies a creation request within one guardian's account.
    # Invalid keys act as absent keys.
    PORTAL_CREATION_KEY_FORMAT = /\A[a-f0-9]{32}\z/

    # GET /constituent_portal/dependents/:id
    def show
      @guardian_relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      @recent_changes = get_recent_profile_changes(@dependent)

      @dependent_applications = @dependent.applications.order(created_at: :desc).limit(5)
    end

    # GET /constituent_portal/dependents/new
    def new
      @dependent_user = User.new
      @guardian_relationship = GuardianRelationship.new
    end

    # GET /constituent_portal/dependents/:id/edit
    def edit
      setup_edit_template_variables
    end

    # POST /constituent_portal/dependents
    def create
      dependent_attrs = dependent_attributes_with_contact_strategies
      unless dependent_attrs
        handle_creation_failure(contact_strategy_errors)
        return
      end
      # Before duplicate detection, replay, and admission: each compares a date of birth, and an
      # unreadable one must not match, or be refused as, anyone's.
      if DateInputNormalizer.invalid?(dependent_user_params[:date_of_birth])
        handle_creation_failure([t('.invalid_date_of_birth')])
        return
      end
      duplicate_detection = detect_portal_dependent_duplicates(dependent_attrs)
      return unless duplicate_detection
      return if portal_dependent_duplicate_blocked?(duplicate_detection, dependent_attrs)

      participant_ids = portal_dependent_creation_participant_ids(duplicate_detection)
      preallocated_synthetic_phone = preallocated_synthetic_phone_from(dependent_attrs)

      create_portal_dependent_atomically(
        duplicate_detection,
        participant_ids,
        preallocated_synthetic_phone
      )
    end

    # PATCH/PUT /constituent_portal/dependents/:id
    #
    # The merge writer uses the same user locks.
    # Revalidate access under these locks because the request's initial authorization precedes them.
    def update
      ActiveRecord::Base.transaction do
        locked_users = User.lock_for_merge_integrity!(@dependent, current_user)
        locked_dependent = locked_users.fetch(@dependent.id)
        locked_guardian = locked_users.fetch(current_user.id)

        unless dependent_edit_still_authorized?(locked_dependent, locked_guardian)
          redirect_to constituent_portal_dashboard_path, alert: 'This dependent is no longer available to edit.'
          raise ActiveRecord::Rollback
        end

        @dependent = locked_dependent

        # Use the locked guardian when the strategy copies contact values into the dependent's record.
        # Pre-lock values could restore contact that a concurrent merge replaced.
        params_to_update = dependent_attributes_with_contact_strategies(locked_guardian)
        unless params_to_update
          contact_strategy_errors.each { |error| @dependent.errors.add(:base, error) }
          setup_edit_template_variables
          render :edit, status: :unprocessable_content
          raise ActiveRecord::Rollback
        end

        if @dependent.update(params_to_update)
          redirect_after_successful_update
        else
          setup_edit_template_variables
          render :edit, status: :unprocessable_content
          raise ActiveRecord::Rollback
        end
      end
    end

    # DELETE /constituent_portal/dependents/:id
    def destroy
      # Keep the dependent's user record because other guardians or applications can still refer to it.
      relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      if relationship&.destroy
        # if !@dependent.guardians.exists? && !@dependent.applications.exists?
        #   @dependent.destroy
        # end
        redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully removed.'
      else
        redirect_to constituent_portal_dashboard_path, alert: 'Failed to remove dependent.'
      end
    end

    private

    # Guardian access can change after the request passes its initial authorization.
    # Dependent login status and STI type do not affect this authorization.
    # A guardian can still edit an unmerged inactive or suspended dependent.
    # The relationship lock makes concurrent removal wait until this transaction ends.
    # See the inactive/suspended cases in test/controllers/constituent_portal/dependents_controller_test.rb.
    def dependent_edit_still_authorized?(locked_dependent, locked_guardian)
      return false if locked_dependent.merged?
      return false unless locked_guardian.public_login_active? && locked_guardian.constituent?

      GuardianRelationship
        .where(guardian_id: locked_guardian.id, dependent_id: locked_dependent.id)
        .order(:id)
        .lock
        .first
        .present?
    end

    def set_dependent
      @dependent = User.editable_by_guardian(current_user).find_by(id: params[:id])

      return if @dependent

      redirect_to constituent_portal_dashboard_path, alert: 'Dependent not found.'
    end

    def dependent_user_params
      params.expect(dependent: %i[first_name last_name email phone phone_type date_of_birth
                                  hearing_disability vision_disability
                                  speech_disability mobility_disability cognition_disability
                                  newsletter_signup])
    end

    def guardian_relationship_params
      params.expect(guardian_relationship: [:relationship_type])
    end

    def require_constituent!
      return if current_user&.constituent?

      redirect_to root_path, alert: 'Access denied. Constituent-only area.'
    end

    def set_current_user
      Current.user = current_user
    end

    # The guardian strategy copies contact from +guardian+ into the dependent's fields.
    # If the caller holds a user lock, +guardian+ must be the locked record.
    def dependent_attributes_with_contact_strategies(guardian = current_user, preallocated_synthetic_phone: nil)
      attrs = dependent_user_params.to_h
      strategies = dependent_contact_strategy_params(attrs, guardian)
      return attrs if strategies.values_at(:email_strategy, :phone_strategy).all?(&:nil?)

      Applications::GuardianDependentManagementService
        .new(strategies, preallocated_synthetic_phone: preallocated_synthetic_phone)
        .tap { |service| @contact_strategy_service = service }
        .apply_contact_strategies_for(guardian, attrs)
    ensure
      @contact_strategy_errors = @contact_strategy_service&.errors if @contact_strategy_service&.errors&.any?
    end

    def contact_strategy_errors
      @contact_strategy_errors.presence || ['Unable to apply dependent contact strategy']
    end

    def detect_portal_dependent_duplicates(attrs)
      result = DuplicateDetectionService.new(
        context: :portal_new_dependent,
        attrs: duplicate_detection_attrs(attrs)
      ).call
      return result.data if result.success?

      log_user_service_error('to evaluate dependent duplicate review', result.message)
      handle_creation_failure(['Unable to complete dependent creation. Please try again.'])
      nil
    end

    def submitted_portal_creation_key
      key = params[:portal_creation_key].to_s
      key.match?(PORTAL_CREATION_KEY_FORMAT) ? key : nil
    end

    # Support must resolve distinct people who share a name and birthdate under this guardian.
    def duplicate_identity_message(existing_dependent)
      t('constituent_portal.dependents.create.duplicate_identity',
        name: existing_dependent.full_name,
        support_email: Policy.get('support_email') || 'mat.program1@maryland.gov',
        support_phone: Policy.get('support_phone') || '410-767-6960')
    end

    # A replay redirects without writes. Refusals render after rollback.
    def apply_portal_dependent_admission(admission)
      return admission[:errors] if admission[:notice].blank?

      redirect_to constituent_portal_dashboard_path, notice: admission[:notice]
      nil
    end

    # Recognize a repeated request before applying the identity rule for a new request.
    # A new form key does not override that rule.
    # Returns a notice for replay, errors for refusal, or nil to continue.
    def portal_dependent_admission(locked_guardian, dependent_attrs)
      replay = replayed_dependent_creation(locked_guardian, dependent_attrs)
      return { errors: [t('constituent_portal.dependents.create.stale_request')] } if replay == :conflict

      if replay
        return { notice: t('constituent_portal.dependents.create.already_added',
                           name: replay.dependent_user.full_name) }
      end

      existing = guardian_scoped_identity_match(locked_guardian, dependent_attrs)
      return { errors: [duplicate_identity_message(existing)] } if existing

      nil
    end

    # Replay lookup uses the guardian ID and form key, as the unique index does.
    # The same key in another guardian's account identifies a separate request.
    #
    # Returns the original relationship for unchanged input, :conflict for changed input,
    # or nil for an absent or unused key.
    # A legacy form without a key still passes through the identity guard.
    def replayed_dependent_creation(guardian, _dependent_attrs)
      key = submitted_portal_creation_key
      return nil if key.blank?

      existing = GuardianRelationship.includes(:dependent_user)
                                     .find_by(guardian_id: guardian.id, portal_creation_key: key)
      return nil if existing.blank?

      existing.portal_creation_fingerprint == submitted_request_fingerprint ? existing : :conflict
    end

    # Use submitted fields and raw use_guardian_* choices for replay identity.
    # Stored contact can contain generated values or copies of guardian contact.
    # A guardian contact edit must not change whether the server recognizes a repeated request.
    def submitted_request_fingerprint
      DependentRequestFingerprint.new(
        dependent_params: dependent_user_params.to_h,
        relationship_type: guardian_relationship_params[:relationship_type],
        use_guardian_email: params[:use_guardian_email],
        use_guardian_phone: params[:use_guardian_phone]
      ).to_s
    end

    # This portal guard compares constituents this guardian already manages.
    # A matching name and birthdate blocks a new request.
    # Users::Constituent.find_duplicates owns the comparison after duplicate_detection_attrs casts the birthdate.
    # The query includes relationships from paper and admin intake.
    # This portal lock does not serialize concurrent writes by those entrypoints.
    def guardian_scoped_identity_match(locked_guardian, dependent_attrs)
      attrs = duplicate_detection_attrs(dependent_attrs)
      first_name = attrs[:first_name].to_s.strip
      last_name = attrs[:last_name].to_s.strip
      date_of_birth = attrs[:date_of_birth]
      return nil if first_name.blank? || last_name.blank? || date_of_birth.blank?

      dependent_ids = GuardianRelationship.where(guardian_id: locked_guardian.id).select(:dependent_id)
      Users::Constituent.find_duplicates(first_name, last_name, date_of_birth)
                        .where(id: dependent_ids)
                        .first
    end

    # Exact-contact detection can block a replay against the dependent it created.
    # Let a possible replay reach the locked admission check before deciding its outcome.
    # This unlocked lookup is advisory. A concurrent first request can commit before the locked check.
    def portal_dependent_duplicate_blocked?(duplicate_detection, dependent_attrs)
      return false unless duplicate_detection.hard_block
      return false if replayed_dependent_creation(current_user, dependent_attrs).present?

      handle_creation_failure(['Unable to complete dependent creation. Please contact the MAT Team for assistance.'])
      true
    end

    # New portal dependents require disability validation and must not reuse a user lookup result.
    def create_portal_dependent_user(dependent_attrs)
      create_user_with_service(dependent_attrs,
                               is_managing_adult: false,
                               skip_user_lookup: true,
                               require_disability_validation: true)
    end

    # Duplicate detection supplies the persisted candidates before this transaction.
    # Lock the guardian and review candidates in ascending ID order before any write.
    # The new dependent has no row to lock yet.
    def create_portal_dependent_atomically(duplicate_detection, participant_ids, preallocated_synthetic_phone)
      failure_messages = nil

      ActiveRecord::Base.transaction do
        locked_users = lock_creation_participants(participant_ids)
        unless locked_users
          failure_messages = ['Unable to complete dependent creation. Please try again.']
          raise ActiveRecord::Rollback
        end

        locked_guardian = locked_users.fetch(current_user.id)

        unless locked_guardian.public_login_active? && locked_guardian.constituent?
          failure_messages = ['Unable to complete dependent creation. Please try again.']
          raise ActiveRecord::Rollback
        end

        dependent_attrs = dependent_attributes_with_contact_strategies(
          locked_guardian,
          preallocated_synthetic_phone: preallocated_synthetic_phone
        )
        unless dependent_attrs
          failure_messages = contact_strategy_errors
          raise ActiveRecord::Rollback
        end

        admission = portal_dependent_admission(locked_guardian, dependent_attrs)
        if admission
          failure_messages = apply_portal_dependent_admission(admission)
          raise ActiveRecord::Rollback
        end

        record_applied_contact_choices

        result = create_portal_dependent_user(dependent_attrs)
        unless result.success?
          failure_messages = result.data[:errors] || [result.message]
          log_user_service_error('to create dependent user', failure_messages)
          raise ActiveRecord::Rollback
        end

        @dependent_user = result.data[:user]
        relationship_created = create_guardian_relationship_with_service(
          locked_guardian,
          @dependent_user,
          guardian_relationship_params[:relationship_type],
          portal_creation_key: submitted_portal_creation_key,
          portal_creation_fingerprint: (submitted_request_fingerprint if submitted_portal_creation_key)
        )
        unless relationship_created
          log_user_service_error('to create guardian relationship', 'Relationship creation failed')
          failure_messages = ['Failed to create guardian relationship']
          raise ActiveRecord::Rollback
        end

        unless open_portal_dependent_duplicate_review_case(duplicate_detection, locked_guardian, locked_users)
          log_user_service_error('to open duplicate review case', 'Duplicate review case creation failed')
          failure_messages = ['Unable to complete dependent creation. Please try again.']
          raise ActiveRecord::Rollback
        end

        redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully created.'
      end

      # Render after rollback because a rescued database error can leave PostgreSQL's transaction unusable.
      handle_creation_failure(failure_messages) if failure_messages
    end

    # The shared lock refuses an incomplete participant set.
    # Treat a missing participant as a normal retry condition.
    def lock_creation_participants(participant_ids)
      User.lock_for_merge_integrity!(participant_ids)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def open_portal_dependent_duplicate_review_case(duplicate_detection, locked_guardian, locked_users)
      return true unless duplicate_detection.recommended_action == :flag

      result = DuplicateReviewCases::CreateService.new(
        source: :portal_dependent,
        subject_user: @dependent_user,
        actor: locked_guardian,
        reason_codes: duplicate_detection.reasons,
        candidates: duplicate_review_candidates_for(duplicate_detection, locked_users),
        metadata: { intake_context: 'portal_dependent' }
      ).call
      return true if result.success?

      Rails.logger.warn("Portal dependent duplicate review case failed: #{result.message}")
      false
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("Portal dependent duplicate review case failed: #{e.message}")
      false
    end

    def duplicate_review_candidates_for(duplicate_detection, locked_users)
      duplicate_detection.matched_users.map do |candidate|
        locked_candidate = locked_users.fetch(candidate.id)
        DuplicateReviewCases::CreateService::CandidateInput.new(
          locked_candidate,
          duplicate_detection.reasons.first,
          {
            email_backed_public_portal_account: locked_candidate.email_backed_public_portal_account?,
            real_email: locked_candidate.real_email?,
            real_phone: locked_candidate.real_phone?
          }
        )
      end
    end

    def portal_dependent_creation_participant_ids(duplicate_detection)
      candidate_ids = if duplicate_detection.recommended_action == :flag
                        duplicate_detection.matched_users.filter_map(&:id)
                      else
                        []
                      end
      [current_user.id, *candidate_ids]
    end

    # The initial contact pass already allocated a synthetic phone for duplicate detection.
    # Reuse that phone only if the locked pass still selects guardian contact.
    # Derive the strategy and guardian contact again from the locked guardian.
    def preallocated_synthetic_phone_from(dependent_attrs)
      return unless @contact_strategy_service&.params&.[](:phone_strategy) == 'guardian'
      return unless User.synthetic_dependent_phone?(dependent_attrs[:phone])

      dependent_attrs[:phone]
    end

    def duplicate_detection_attrs(attrs)
      data = attrs.with_indifferent_access

      {
        email: data[:email],
        phone: data[:phone],
        first_name: data[:first_name],
        last_name: data[:last_name],
        date_of_birth: DateInputNormalizer.normalize(data[:date_of_birth]),
        physical_address_1: data[:physical_address_1],
        physical_address_2: data[:physical_address_2],
        city: data[:city],
        state: data[:state],
        zip_code: data[:zip_code]
      }
    end

    def dependent_contact_strategy_params(attrs, guardian)
      {
        email_strategy: contact_strategy_for(:email, :use_guardian_email, attrs, guardian),
        phone_strategy: contact_strategy_for(:phone, :use_guardian_phone, attrs, guardian),
        address_strategy: 'dependent'
      }
    end

    def contact_strategy_for(field, checkbox_param, attrs, guardian)
      submitted = attrs.key?(field) || attrs.key?(field.to_s)
      value = attrs[field] || attrs[field.to_s]

      # On update, omitted fields preserve stored contact.
      if action_name == 'update'
        return nil unless submitted
      elsif !submitted
        return guardian_contact_strategy(checkbox_param, nil, guardian)
      end

      guardian_contact_strategy(checkbox_param, value, guardian)
    end

    def guardian_contact_strategy(param_name, dependent_value, guardian)
      return 'guardian' if ActiveModel::Type::Boolean.new.cast(params[param_name])
      # A submitted blank replaces dependent contact through the guardian strategy.
      return 'guardian' if dependent_value.blank?
      return 'guardian' if matches_guardian_contact?(param_name, dependent_value, guardian)

      'dependent'
    end

    # Compare with the same guardian record that supplies the stored contact values.
    def matches_guardian_contact?(param_name, dependent_value, guardian)
      case param_name
      when :use_guardian_email
        User.normalize_email(dependent_value) == User.normalize_email(guardian.email)
      when :use_guardian_phone
        normalized_phone_digits(dependent_value) == normalized_phone_digits(guardian.phone)
      else
        false
      end
    end

    def normalized_phone_digits(phone)
      phone.to_s.gsub(/\D/, '')
    end

    def get_recent_profile_changes(user)
      Event.where(
        "(action = 'profile_updated' AND user_id = ?) OR (action = 'profile_updated_by_guardian' AND metadata->>'user_id' = ?)",
        user.id, user.id.to_s
      ).order(created_at: :desc).limit(10)
    end

    # A failed form must retain the applied contact choice, even when hidden fields contain typed contact.
    # Inferring the choice from blank fields could change delivery on retry.
    # When no applied choice was captured, derive it from submitted parameters and current_user.
    def capture_guardian_contact_choices
      return unless @use_guardian_email.nil? && @use_guardian_phone.nil?

      attrs = dependent_user_params.to_h
      @use_guardian_email = contact_strategy_for(:email, :use_guardian_email, attrs, current_user) != 'dependent'
      @use_guardian_phone = contact_strategy_for(:phone, :use_guardian_phone, attrs, current_user) != 'dependent'
    end

    # The retry form uses the service's final choices, including fallbacks, from before rollback.
    # Deriving those choices again from current_user could use stale guardian contact.
    def record_applied_contact_choices
      applied = @contact_strategy_service&.params
      return if applied.blank?

      @use_guardian_email = applied[:email_strategy] != 'dependent'
      @use_guardian_phone = applied[:phone_strategy] != 'dependent'
    end

    def handle_creation_failure(errors)
      error_messages = if errors.respond_to?(:full_messages)
                         errors.full_messages
                       elsif errors.is_a?(Array)
                         errors
                       else
                         [errors.to_s]
                       end

      error_prefix = Rails.env.test? ? '[TEST_VALIDATION] ' : ''
      Rails.logger.error "#{error_prefix}Failed to create dependent: #{error_messages.join(', ')}"

      # Rebuild from submitted fields because rollback leaves generated contact values on the failed user object.
      # Showing those values could expose internal placeholders and change contact ownership on retry.
      @dependent_user = User.new(dependent_user_params)
      @guardian_relationship ||= GuardianRelationship.new(guardian_relationship_params)
      capture_guardian_contact_choices

      flash.now[:alert] = "Failed to create dependent: #{error_messages.join(', ')}"
      render :new, status: :unprocessable_content
    end

    def redirect_after_successful_update
      if params[:application_id].present?
        app = Application.find_by(id: params[:application_id])
        if app
          return redirect_to constituent_portal_application_path(app),
                             notice: 'Dependent was successfully updated.'
        end
      end

      redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully updated.'
    end

    def setup_edit_template_variables
      @dependent_user = @dependent
      @guardian_relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)
      @recent_changes = get_recent_profile_changes(@dependent)
    end
  end
end
