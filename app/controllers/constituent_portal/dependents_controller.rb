# frozen_string_literal: true

module ConstituentPortal
  class DependentsController < ApplicationController
    include UserServiceIntegration

    before_action :authenticate_user!
    before_action :require_constituent! # Ensure only constituents can manage dependents
    before_action :set_current_user
    before_action :set_dependent, only: %i[show edit update destroy]

    # GET /constituent_portal/dependents/:id
    def show
      # @dependent is set by before_action
      @guardian_relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      # Get recent profile changes for this dependent
      @recent_changes = get_recent_profile_changes(@dependent)

      # Get dependent's applications if any
      @dependent_applications = @dependent.applications.order(created_at: :desc).limit(5)
    end

    # GET /constituent_portal/dependents/new
    def new
      @dependent_user = User.new # For the dependent's user record
      @guardian_relationship = GuardianRelationship.new # For the relationship_type
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
      duplicate_detection = detect_portal_dependent_duplicates(dependent_attrs)
      return unless duplicate_detection
      return if portal_dependent_duplicate_blocked?(duplicate_detection)

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
    # Locks the dependent and the guardian before requalifying and updating, so a concurrent
    # merge and a concurrent dependent profile edit can never interleave: either the merge
    # commits first and this reload sees the retired participant and refuses, or the edit
    # commits first and the merge -- which takes the same lock -- waits. Also re-derives every
    # authority fact under that lock (see dependent_edit_still_authorized?): set_dependent and
    # require_constituent! both ran before the lock was granted.
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

        # Derived from the *locked* guardian, inside the lock. A guardian contact strategy
        # snapshots the guardian's own email, phone, and delivery preference into the dependent's
        # stored contact, and User#effective_phone prefers that stored dependent_phone -- so
        # deriving these before the lock would let a merge that changed the guardian's contact in
        # the meantime be overwritten by pre-lock values and become durable contact truth,
        # routing the dependent's notifications to a number the merge just discarded.
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
      # @dependent is set by before_action
      # This should destroy the GuardianRelationship.
      # Destroying the dependent User record itself is more complex:
      # - Only if no other guardians?
      # - Only if no applications?
      # Focus on destroying the relationship from current_user's perspective.
      relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      if relationship&.destroy
        # Optionally, check if the dependent user should be destroyed
        # if !@dependent.guardians.exists? && !@dependent.applications.exists?
        #   @dependent.destroy
        # end
        redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully removed.'
      else
        redirect_to constituent_portal_dashboard_path, alert: 'Failed to remove dependent.'
      end
    end

    private

    # Every authority fact behind this edit, re-derived against the locked rows instead of the
    # pre-lock instances the request was authorized with.
    #
    # The two participants are deliberately held to different standards. The guardian is the
    # authenticated actor, so it must still satisfy the same gates the request was admitted
    # under: public_login_active? (an admin suspension or deactivation landing mid-request must
    # end the actor's authority, exactly as it would have blocked sign-in) and constituent?
    # (require_constituent! ran before the lock was granted, so a role conversion in that window
    # would otherwise still be honored). The dependent is a managed record that never
    # authenticates, so only merged? disqualifies it: an admin deactivating or suspending a
    # dependent must not lock their guardian out of maintaining the profile, and the dependent's
    # own STI type is not part of this authorization -- User.editable_by_guardian scopes on the
    # relationship alone. See the "guardian can edit an unmerged inactive/suspended dependent"
    # cases in test/controllers/constituent_portal/dependents_controller_test.rb.
    #
    # The guardian relationship is read FOR UPDATE rather than through an unlocked exists?: an
    # unlocked check can be satisfied by a row that a concurrent removal deletes before the
    # update below lands, whereas locking the row makes that removal wait for this transaction.
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
      # Use Rails-centric scope for authorization
      @dependent = User.editable_by_guardian(current_user).find_by(id: params[:id])

      return if @dependent

      redirect_to constituent_portal_dashboard_path, alert: 'Dependent not found.'
    end

    def dependent_user_params
      # Define strong parameters for the dependent User
      # Ensure to permit all necessary fields for creating a User (e.g., email, name, dob)
      # Handle password creation strategy for dependents (e.g., generate random, or no login)
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

    # +guardian+ is the record whose own contact facts get snapshotted into the dependent's
    # stored contact, so it must be the locked guardian on any path that writes under a lock --
    # never the request's pre-lock current_user.
    def dependent_attributes_with_contact_strategies(guardian = current_user, preallocated_synthetic_phone: nil)
      attrs = dependent_user_params.to_h
      # Portal contact strategies snapshot the submitted choice into User fields.
      # Omitted contact keys preserve existing contact on partial updates.
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

    def portal_dependent_duplicate_blocked?(duplicate_detection)
      return false unless duplicate_detection.hard_block

      handle_creation_failure(['Unable to complete dependent creation. Please contact the MAT Team for assistance.'])
      true
    end

    def create_portal_dependent_user(dependent_attrs)
      create_user_with_service(dependent_attrs,
                               is_managing_adult: false,
                               skip_user_lookup: true,
                               require_disability_validation: true)
    end

    # Duplicate detection must run before this boundary so the complete persisted participant
    # inventory is known. The guardian and every candidate that will be written into a review
    # case are then locked in one ascending-id call before any durable write. The new dependent
    # cannot be included because it does not exist yet and is invisible outside this transaction.
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

        # Using UserServiceIntegration for the existing portal contract: always create a new
        # dependent, never reuse a lookup hit, and require the disability validation.
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
          guardian_relationship_params[:relationship_type]
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

      # Render only after rollback. In particular, CreateService may rescue a database error
      # into a failure result; PostgreSQL rejects every query until that transaction ends.
      handle_creation_failure(failure_messages) if failure_messages
    end

    # lock_for_merge_integrity! refuses to lock a partial participant set: if a candidate resolved
    # during duplicate detection was deleted before this lock was granted, it raises rather than
    # locking fewer rows than asked for. Failing closed is correct, but on this path that is an
    # ordinary concurrent condition, not a server error -- before the lock moved here it was
    # absorbed by open_portal_dependent_duplicate_review_case's rescue and surfaced as the normal
    # retry message. Returning nil keeps that response instead of escaping as a 500.
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

    # The initial, pre-lock contact pass is needed for duplicate detection and already pays the
    # bounded synthetic-phone allocation cost. Reuse only that opaque primary value if the locked
    # pass still chooses the guardian strategy; the strategy itself and every guardian-derived
    # contact fact are recalculated from the locked guardian.
    def preallocated_synthetic_phone_from(dependent_attrs)
      return unless @contact_strategy_service&.params&.[](:phone_strategy) == 'guardian'
      return unless User.synthetic_dependent_phone?(dependent_attrs[:phone])

      dependent_attrs[:phone]
    end

    def duplicate_detection_attrs(attrs)
      data = attrs.with_indifferent_access
      dob_holder = Users::Constituent.new
      dob_holder.date_of_birth = data[:date_of_birth] if data.key?(:date_of_birth)

      {
        email: data[:email],
        phone: data[:phone],
        first_name: data[:first_name],
        last_name: data[:last_name],
        date_of_birth: dob_holder.date_of_birth,
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

      # Update only rewrites contact when the field was submitted; omitted keys preserve stored values.
      if action_name == 'update'
        return nil unless submitted
      elsif !submitted
        return guardian_contact_strategy(checkbox_param, nil, guardian)
      end

      guardian_contact_strategy(checkbox_param, value, guardian)
    end

    def guardian_contact_strategy(param_name, dependent_value, guardian)
      return 'guardian' if ActiveModel::Type::Boolean.new.cast(params[param_name])
      # Submitted blank contact on create/update applies guardian strategy and regenerates primary contact.
      return 'guardian' if dependent_value.blank?
      return 'guardian' if matches_guardian_contact?(param_name, dependent_value, guardian)

      'dependent'
    end

    # Compares against the passed guardian, not current_user: deciding "the submitted value is
    # the guardian's own contact, so use the guardian strategy" is only correct against the same
    # guardian record whose values will then be snapshotted.
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

    # Get recent profile changes for a user
    def get_recent_profile_changes(user)
      Event.where(
        "(action = 'profile_updated' AND user_id = ?) OR (action = 'profile_updated_by_guardian' AND metadata->>'user_id' = ?)",
        user.id, user.id.to_s
      ).order(created_at: :desc).limit(10)
    end

    def handle_creation_failure(errors)
      # Handle both array of strings and ActiveModel::Errors objects
      error_messages = if errors.respond_to?(:full_messages)
                         errors.full_messages
                       elsif errors.is_a?(Array)
                         errors
                       else
                         [errors.to_s]
                       end

      error_prefix = Rails.env.test? ? '[TEST_VALIDATION] ' : ''
      Rails.logger.error "#{error_prefix}Failed to create dependent: #{error_messages.join(', ')}"

      # Set up form variables for re-rendering
      # A relationship/case failure reaches here while the new user is still persisted inside
      # the transaction that is about to roll back. Do not render the new form with that
      # transient persisted object: form_with would target the member PATCH route for a row
      # that no longer exists after rollback.
      @dependent_user = User.new(dependent_user_params) if @dependent_user&.persisted?
      @dependent_user ||= User.new(dependent_user_params)
      @guardian_relationship ||= GuardianRelationship.new(guardian_relationship_params)

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
