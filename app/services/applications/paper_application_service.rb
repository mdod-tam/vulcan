# frozen_string_literal: true

module Applications
  # This service handles paper application submissions by administrators
  # It follows the same patterns as ConstituentPortal for file uploads
  # rubocop:disable Metrics/ClassLength
  class PaperApplicationService < BaseService
    include Rails.application.routes.url_helpers

    class TransactionFailure < StandardError; end

    # A post-creation step that knows why it failed. The wrapper names the step; this carries the
    # actionable detail with it, so a step can report a failed *result* -- not only a raised
    # exception -- and still get the named warning and the durable event.
    class PostCreationStepFailure < StandardError; end

    # Named distinctly from the post-creation steps so the timeline separates "a callback raised
    # after the data was already durable" from "a follow-up step we run ourselves did not finish".
    # The two need different handling: the callback is deliberately not retried, because it may have
    # completed some of its side effects before raising.
    POST_COMMIT_CALLBACK_STEP = 'a post-commit callback'

    attr_reader :params, :admin, :application, :constituent, :errors, :guardian_user_for_app, :reconciliation_note,
                :pending_identity_decision, :warnings

    def initialize(params:, admin:, skip_income_validation: false, skip_proof_processing: false,
                   quick_created_portal_user_ids: [])
      super()
      @params = params.with_indifferent_access
      @admin = admin
      @application = nil
      @constituent = nil
      @guardian_user_for_app = nil
      @errors = []
      @created_portal_user_ids = []
      @quick_created_portal_user_ids = quick_created_portal_user_ids.map(&:to_s)
      @reconciliation_note = nil
      @warnings = []
      @commit_confirmed = true
      @pending_identity_decision = nil
      @confirmed_no_match = nil
      @skip_income_validation = skip_income_validation
      @skip_proof_processing = skip_proof_processing
    end

    def create
      Current.paper_context = true
      application_created = run_create_transaction

      # An unverified write gets no further work against the same record. Whatever stopped us
      # confirming the commit would raise again here, and that exception is caught below as a
      # *failure* -- turning a possibly-committed application into a retry form, which is the
      # duplicate this path exists to prevent. The warning already tells staff to check the list.
      if application_created && commit_confirmed?
        begin
          handle_successful_application(:create)
        rescue StandardError => e
          # Logged *and* surfaced. This method sequences notifications, proof-delivery checks, audit
          # logging and provider follow-up, so one exception can also skip everything after it --
          # silently succeeding here tells the admin the paper intake finished when part of it did
          # not.
          log_error(e, 'Failed to finish post-creation steps after a successful application creation')
          add_warning('The application was created, but a follow-up step did not finish. ' \
                      'Review this application before treating it as complete.')
        end

        # Reconcile outside the transaction so proof writes are committed regardless of
        # reconciliation outcome. Failure here means the application is stuck at the wrong
        # status, and we surface that to the admin via reconciliation_note.
        reconcile_after_paper_write(:paper_application_created)
      end

      application_created
    rescue GuardianDependentManagementService::DependentCreationConflict
      recover_dependent_creation_conflict
    rescue TransactionFailure
      false
    rescue StandardError => e
      log_error(e, 'Failed to create paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    def update(application)
      Current.paper_context = true
      update_succeeded = false

      ActiveRecord::Base.transaction do
        @application = application
        @constituent = application.user

        rollback_failure('Application update failed') unless update_application_attributes
        rollback_failure('Proof upload failed') unless process_proof_uploads

        update_succeeded = true
      end

      reconcile_after_paper_write(:paper_application_updated) if update_succeeded

      update_succeeded
    rescue TransactionFailure
      false
    rescue StandardError => e
      log_error(e, 'Failed to update paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    # Everything the admin should be told about a *successful* write, in one place. Reconciliation
    # keeps its own note because it names a specific recoverable state ("advance it manually"); a
    # post-commit callback failure is a different thing and should not borrow that label. Both are
    # surfaced together so a request that hit each one does not silently drop the first.
    def warning_message
      [@reconciliation_note, *@warnings].compact_blank.join(' ').presence
    end

    # False only when the write could not be verified. A true result is still not a retry -- but the
    # caller must not route an unconfirmed write to the record's own page.
    def commit_confirmed?
      @commit_confirmed
    end

    ADULT_CONTACT_FIELDS = %i[
      email phone phone_type physical_address_1 physical_address_2
      city state zip_code communication_preference locale
      preferred_means_of_communication referral_source
    ].freeze
    APPLICANT_DISABILITY_FIELDS = %i[
      hearing_disability vision_disability speech_disability
      mobility_disability cognition_disability
    ].freeze

    private

    # Owns the one question the caller cannot answer for itself: did this commit?
    #
    # `after_commit` callbacks run as the transaction block exits, so an exception from one -- for
    # instance ProofReview's post-review actions, which every rejected proof triggers -- escapes the
    # block *after* the data is durable. Left to the outer rescue that becomes "false" for an
    # application that exists, and a caller that treats false as "nothing happened" invites the admin
    # to submit again and create a duplicate.
    #
    # Durable existence is asked of the database rather than of the in-memory record, because
    # `persisted?` is exactly the authority that was wrong here in both directions: false after a
    # rollback restores the record, and true after a commit whose callback then blew up.
    #
    # The callback is deliberately not retried. It raised partway through, so some of its side
    # effects may already have happened; running it again could duplicate them. The failure is
    # recorded as a warning and the ordinary post-commit path continues once.
    def run_create_transaction
      ActiveRecord::Base.transaction do
        rollback_failure_unless_explained('Constituent processing failed') unless process_constituent
        rollback_failure('Application creation failed') unless create_application
        rollback_failure_unless_explained('Proof upload failed') unless @skip_proof_processing || process_proof_uploads

        @application.persisted?
      end
    rescue TransactionFailure
      raise
    rescue StandardError => e
      state = commit_state
      # Only a *confirmed* rollback may become a failure, because failure sends the admin back to a
      # retry form. Anything else stays on the success side.
      raise if state == :rolled_back

      log_error(e, 'Paper application post-commit step failed')
      # Recorded so the caller can avoid routing to a record it cannot be sure exists. Sending staff
      # to an application detail page that 404s would replace "check before retrying" with
      # "application not found" -- the same substitution this whole change set exists to stop.
      @commit_confirmed = (state == :committed)
      add_warning(post_commit_warning_for(state))
      # A confirmed commit left durable data behind, so the record of unfinished work has to be
      # durable too -- the flash is gone after one page view, and this is the path that motivated
      # the whole contract. Only when confirmed: on an unknown commit the database is the thing
      # that just failed, and there may be no application row to hang the event on.
      record_incomplete_follow_up(POST_COMMIT_CALLBACK_STEP, e) if @commit_confirmed
      true
    end

    def post_commit_warning_for(state)
      if state == :unknown
        'The application may have been created, but that could not be confirmed. Check the ' \
          'applications list before entering it again -- submitting again could create a duplicate.'
      else
        'The application was created, but a follow-up step did not finish. ' \
          'Review this application before treating it as complete.'
      end
    end

    # Three answers, not two. Collapsing "I could not tell" into "not committed" is what would
    # recreate the duplicate risk: the post-commit callback raises, the verification query then fails
    # transiently, and an application that exists gets offered back as a retry.
    #
    # Asked of the database on the same connection that just performed the write, which is the
    # writer: this application configures no reader role. If one is ever added, this query must stay
    # on the writer -- replica lag answering "no" about a row committed moments ago is the same
    # mistake by a different route.
    #
    # @return [Symbol] :committed, :rolled_back, or :unknown
    def commit_state
      id = @application&.id
      return :rolled_back if id.blank?

      Application.exists?(id) ? :committed : :rolled_back
    rescue StandardError => e
      log_error(e, 'Could not confirm whether the paper application committed')
      :unknown
    end

    def add_warning(message)
      @warnings << message unless @warnings.include?(message)
    end

    def failure(message)
      @errors << message
      false
    end

    def rollback_failure(message)
      failure(message)
      raise TransactionFailure, message
    end

    # Same as rollback_failure, but skips the generic step-name message when the step
    # already recorded a specific, staff-facing reason via add_error (e.g. "An applicant
    # with this email or phone already exists..."). Without this, staff see a redundant,
    # internal-sounding tail like "; Constituent processing failed" appended after the
    # real explanation.
    def rollback_failure_unless_explained(message)
      failure(message) if @errors.empty?
      raise TransactionFailure, message
    end

    # The audit event goes first because it is the durable record that this application was created
    # at all. It used to run after notifications; a mail failure therefore skipped it, leaving a
    # committed application with no `application_created` event.
    #
    # First, but not unguarded: every step on the create path is isolated, including the audit
    # itself. Running it bare simply moved the hazard -- `AuditEventService` writes with
    # `Event.create!`, so a failed audit raised straight past notifications, proof-delivery checks
    # and the provider request, and past the durable record that any of them had been skipped.
    #
    # The steps are independent: a notification problem is no reason to skip the provider request,
    # and a missing audit row is no reason to skip all three. The caller is told which ones did not
    # finish.
    #
    # `:update` is left as it was. Paper applications route only `new` and `create`, the controller
    # defines only those two actions, and `#update` has no production caller -- so changing its
    # behavior here would be an untestable claim about a path nothing reaches.
    def handle_successful_application(operation = :create)
      case operation
      when :create then run_post_creation_step('the creation audit event') { log_application_creation }
      when :update
        log_application_update
      end

      run_post_creation_step('notifications') { send_notifications }
      run_post_creation_step('proof delivery checks') { append_proof_resubmission_delivery_warnings }
      run_post_creation_step('the certifying provider request') { request_provider_info_if_missing } if operation == :create
    end

    def run_post_creation_step(description)
      yield
    rescue StandardError => e
      # Two different audiences, two different exceptions. The typed wrapper carries the sentence
      # staff need; its `cause` carries the diagnosis. `log_error` reads only `message` and
      # `backtrace`, so logging the wrapper would report `PostCreationStepFailure` with the
      # wrapper's own backtrace and the real error would never reach the log -- and `error_class`
      # on the audit event would name the wrapper rather than what actually failed.
      diagnostic = e.cause || e
      log_error(diagnostic, "Paper application post-creation step failed: #{description}")
      detail = e.is_a?(PostCreationStepFailure) ? "#{e.message} " : ''
      add_warning("The application was created, but #{description} did not finish. #{detail}" \
                  'Review this application before treating it as complete.')
      record_incomplete_follow_up(description, diagnostic)
    end

    # A flash message lasts one page view. Whoever picks this application up tomorrow needs to know
    # a step did not finish, so it is written to the audit trail beside the creation event. Best
    # effort by design: if the audit write itself fails there is nothing further to fall back on, and
    # it must not turn a committed application into an error.
    def record_incomplete_follow_up(description, error)
      AuditEventService.log(
        action: 'application_post_creation_step_failed',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          step: description,
          error_class: error.class.name
        }
      )
    rescue StandardError => e
      log_error(e, 'Could not record the incomplete paper follow-up step')
    end

    def log_application_creation
      AuditEventService.log(
        action: 'application_created',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          initial_status: (@application.status || 'in_progress').to_s
        }
      )
    end

    def log_application_update
      AuditEventService.log(
        action: 'application_updated',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          updated_attributes: @application.saved_changes.keys,
          proof_actions: {
            income: params[:income_proof_action],
            residency: params[:residency_proof_action]
          }.compact
        }
      )
    end

    def process_constituent
      guardian_id = params[:guardian_id]
      applicant_data = params[:constituent]
      relationship_type = params[:relationship_type]
      dependent_id = params[:dependent_id]
      existing_constituent_id = params[:existing_constituent_id]

      if existing_self_applicant_scenario?(existing_constituent_id)
        process_existing_self_applicant(existing_constituent_id)
      elsif existing_dependent_scenario?(guardian_id, dependent_id)
        process_existing_dependent(guardian_id, dependent_id, relationship_type)
      elsif guardian_scenario?(guardian_id, applicant_data)
        process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      elsif self_applicant_scenario?(applicant_data)
        process_self_applicant(applicant_data)
      elsif dependent_with_unsaved_guardian?(applicant_data)
        add_error('Save or select the guardian before submitting the paper application.')
      else
        add_error('Sufficient constituent or guardian/dependent parameters missing.')
        false
      end
    end

    def existing_self_applicant_scenario?(existing_constituent_id)
      existing_constituent_id.present? && params[:applicant_type] != 'dependent'
    end

    def process_existing_self_applicant(existing_constituent_id)
      user = User.find_by(id: existing_constituent_id)
      return add_error('Applicant not found') unless user
      return add_error('Selected user is not eligible as an applicant.') unless user.paper_applicant_candidate?

      # Dual eligibility check
      return add_error('This constituent already has an active or pending application.') if user.applications.blocking_new_submission.exists?

      return false unless waiting_period_eligible?(user)

      return add_error('Verify contact information against the paper application before submitting.') unless existing_adult_contact_info_verified?

      @constituent = user

      return false unless update_existing_applicant_disability_info(user)

      if params[:constituent].present? && attributes_present?(params[:constituent]) &&
         existing_adult_contact_updates_allowed? && !update_existing_adult_contact_info(user)
        return false
      end

      true
    end

    def existing_adult_contact_info_verified?
      ActiveModel::Type::Boolean.new.cast(params.fetch(:contact_info_verified, false))
    end

    def existing_adult_contact_updates_allowed?
      params[:contact_info_mode].to_s != 'on_file'
    end

    def guardian_scenario?(guardian_id, applicant_data)
      guardian_id.present? && attributes_present?(applicant_data) &&
        params[:applicant_type] == 'dependent'
    end

    def existing_dependent_scenario?(guardian_id, dependent_id)
      guardian_id.present? && dependent_id.present? && params[:applicant_type] == 'dependent'
    end

    def process_existing_dependent(guardian_id, dependent_id, _relationship_type)
      locked_users = User.lock.where(id: [guardian_id, dependent_id]).order(:id).index_by { |user| user.id.to_s }
      guardian = locked_users[guardian_id.to_s]
      dependent = locked_users[dependent_id.to_s]

      return add_error('Guardian not found') unless guardian
      return add_error('Dependent not found') unless dependent
      return add_error('Selected guardian is not an eligible active constituent.') unless guardian.paper_guardian_candidate?
      return add_error('Selected dependent is not an eligible constituent.') unless dependent.paper_dependent_candidate?

      return false unless ensure_guardian_relationship(guardian, dependent)
      return false unless update_dependent_and_validate_eligibility(dependent)

      @guardian_user_for_app = guardian
      @constituent = dependent
      true
    end

    def ensure_guardian_relationship(guardian, dependent)
      rel = GuardianRelationship.lock.find_by(guardian_id: guardian.id, dependent_id: dependent.id)
      return true if rel.present?

      add_error('The selected dependent is not on file for this guardian. Choose an on-file dependent or contact MAT support.')
    end

    def update_dependent_and_validate_eligibility(dependent)
      return add_error('This dependent already has an active or pending application.') if dependent.applications.blocking_new_submission.exists?
      return false unless waiting_period_eligible?(dependent)

      return false unless update_existing_applicant_disability_info(dependent)

      # Update dependent information if provided (contact info may have changed)
      return false if params[:constituent].present? && attributes_present?(params[:constituent]) && !update_dependent_contact_info(dependent)

      true
    end

    def waiting_period_eligible?(user)
      last_app = user.applications.order(application_date: :desc).first
      return true if last_app.blank?

      waiting_period = Policy.get('waiting_period_years') || 3
      eligible_date = last_app.application_date + waiting_period.years
      return true if eligible_date <= Time.current

      add_error("Not yet eligible for a new application. Eligible after #{eligible_date.to_date.strftime('%B %d, %Y')}.")
      false
    end

    def self_applicant_scenario?(applicant_data)
      attributes_present?(applicant_data) && params[:applicant_type] != 'dependent'
    end

    def dependent_with_unsaved_guardian?(applicant_data)
      params[:applicant_type] == 'dependent' &&
        (ActiveModel::Type::Boolean.new.cast(params[:unsaved_guardian_present]) ||
         attributes_present?(applicant_data) || attributes_present?(params[:guardian_attributes]))
    end

    def process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      service = GuardianDependentManagementService.new(params, actor: @admin)
      result = service.process_guardian_scenario(guardian_id, applicant_data, relationship_type)

      if result.success?
        @guardian_user_for_app = result.data[:guardian]
        @constituent = result.data[:dependent]

        track_email_backed_portal_created_user_ids(result.data[:email_backed_portal_created_user_ids])

        validate_no_active_application('dependent')
      else
        @errors.concat(service.errors)
        false
      end
    end

    # PostgreSQL aborts a transaction after a unique-index violation, so classification cannot run
    # inside GuardianDependentManagementService's transaction. Its narrow wrapper escapes the
    # transaction; only then do we recompute the paper identity review against the now-committed
    # winner. No write is retried here.
    def recover_dependent_creation_conflict
      Rails.logger.warn('Dependent creation hit a unique constraint; identity review recomputed after rollback')
      guardian = User.find_by(id: params[:guardian_id])
      review = if guardian&.paper_guardian_candidate?
                 Applications::PaperIdentityReview.new(
                   constituent_params: params[:constituent],
                   contact_flag_params: params,
                   admin: @admin,
                   submitted_token: nil,
                   context: :dependent,
                   context_data: { guardian: guardian, relationship_type: params[:relationship_type] }
                 ).call
               end

      if review&.blocked?
        add_error(GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE)
      else
        add_error('Dependent contact information changed while saving. ' \
                  'Review the dependent before trying again.')
      end
    rescue StandardError => e
      log_error(e, 'Could not classify a dependent creation conflict after rollback')
      add_error('Dependent contact information changed while saving. ' \
                'Review the dependent before trying again.')
    end

    def process_self_applicant(applicant_data)
      contact_flags = paper_contact_flags(:constituent)
      review = review_paper_identity(applicant_data)
      return false unless identity_review_permits_creation?(review)

      applicant_data = contact_flags.apply_to(applicant_data)

      result = UserCreationService.new(
        applicant_data,
        is_managing_adult: true,
        skip_user_lookup: true,
        skip_email_validation: contact_flags.skip_email_validation?,
        skip_phone_validation: contact_flags.skip_phone_validation?
      ).call

      if result.success?
        @constituent = result.data[:user]
        track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])

        # Deliberately no duplicate-review case here. Staff have just reviewed this exact candidate
        # set and attested that none of them is this applicant; opening a case would queue that same
        # decision for someone to make again. Paper cases are also resolvable but never mergeable,
        # so the queue entry could be closed and never remediated.
        #
        # The case was, however, the only durable record of who decided what. Removing it without
        # replacement would leave the enforcement provable only for the length of one request, so a
        # successful confirmation writes its own evidence instead.
        record_no_match_confirmation(@constituent)

        return false unless validate_no_active_application('constituent')
        return false unless waiting_period_eligible?(@constituent)

        true
      else
        @errors.concat(result.data[:errors] || [result.message])
        false
      end
    end

    # The whole identity question is answered by PaperIdentityReview, which the preview endpoint
    # calls too. Nothing about detection, hard blocks, candidates, reasons or decision verification
    # is re-derived here: a second implementation is exactly how a preview and a write boundary come
    # to disagree.
    def review_paper_identity(applicant_data)
      review = Applications::PaperIdentityReview.new(
        constituent_params: applicant_data,
        admin: @admin,
        contact_flag_params: params,
        submitted_token: params[:identity_decision]
      )

      # Taken from the review's own facts, before it runs, so the thing being locked and the thing
      # being searched for are the same by construction.
      Applications::PaperIdentityCreationLock.lock!(review.identity_facts)
      review.call
    end

    # The review answers a question about the rows that exist *now*, and the creation immediately
    # afterwards adds one. Between those two steps another request can do exactly the same thing, so
    # two concurrent submissions of the same person each see a clean search and each create: one
    # signed decision spent twice on the override path, and on the zero-match path a duplicate with
    # no decision involved at all. Recomputing at the write boundary closes stale *client* state; it
    # does nothing about two writers racing.
    #
    # There is no row to lock for an identity that does not exist yet, so the lock is taken on the
    # identity itself -- a transaction-scoped Postgres advisory lock keyed by the same canonical
    # facts detection runs on. Transaction-scoped means Postgres releases it on commit *or*
    # rollback, so a failed or rolled-back write can never strand the key.
    #
    # The key is the *matching* identity -- canonical name and date of birth -- not the whole fact
    # set. Keying on everything looked safer and was strictly worse: two submissions for the same
    # person carrying different emails would hash to different keys, take different locks, and race
    # exactly as before. Name and date of birth is the equivalence Users::Constituent.find_duplicates
    # itself uses, so the lock covers precisely the pairs detection would call the same person.
    # Identical contact values are already excluded by the unique index; this covers the case that
    # index cannot see.
    #
    # This serializes same-identity submissions only. Two different applicants hash to different
    # keys and never wait on each other, so ordinary concurrent paper intake is unaffected.
    # Paper intake asks staff to decide only where the computer is unsure. Selecting a surfaced
    # constituent is enforced by existing_self_applicant_scenario?; this is the other half of that
    # choice -- recording that the surfaced candidates are different people.
    #
    #   error              -> detection itself failed; refuse rather than guess
    #   blocked            -> exact contact collision; never acknowledgeable
    #   clear              -> nothing surfaced; create
    #   needs_confirmation -> staff must decide about what surfaced; write nothing
    #   confirmed          -> staff decided these are different people; create
    #
    # Staff are asked only where the computer is genuinely unsure. Two people can legitimately share
    # a name and date of birth, so a soft match is a real decision: creating automatically risks a
    # duplicate, refusing automatically turns away a legitimate applicant. Nothing surfacing is not
    # a decision, and asking for a click there would prove nothing the server's own search -- run
    # against the completed applicant immediately before this write -- has not already established.
    #
    # The review recomputes from the *submitted* facts rather than trusting the request, so a form
    # searched under one name and submitted under another presents a candidate set the decision was
    # never issued for. That closes stale client state; concurrent writers racing between the read
    # and the write are closed separately, by PaperIdentityCreationLock.
    def identity_review_permits_creation?(review)
      return add_error('Duplicate detection failed. Try again.') if review.error?
      return add_error('The applicant details or possible matches changed since you reviewed them. Review again.') if review.invalid_decision?

      if review.blocked?
        return add_error('An applicant with this email or phone already exists. ' \
                         'Select the existing applicant instead of creating a new one.')
      end

      # Evidence is recorded only for an actual override: who looked at which records and said they
      # are different people. An ordinary application with nothing to decide has no decision to log.
      if review.confirmed?
        @confirmed_no_match = { candidate_ids: review.candidate_ids, reason_codes: review.reasons }
        return true
      end

      return true if review.clear?

      @pending_identity_decision = {
        candidates: review.candidates,
        selectable_candidates: review.selectable_candidates,
        reasons: review.reasons,
        token: review.token,
        reason: review.decision_reason
      }
      add_error(no_match_decision_error(review.decision_reason, review.candidates.size))
      false
    end

    def no_match_decision_error(reason, candidate_count)
      return 'This review expired. Search again before creating a new constituent.' if reason == :expired

      if reason == :mismatched
        return 'The applicant details or the possible matches changed since you reviewed them. ' \
               'Search again before creating a new constituent.'
      end

      "#{candidate_count} possible #{'match'.pluralize(candidate_count)} found. " \
        'Review them and either select the existing constituent or confirm this is a different person.'
    end

    # One event per *successful* confirmation. Missing, forged, expired and abandoned reviews write
    # nothing, so the trail records decisions taken rather than attempts made.
    #
    # Carries who confirmed, what they were shown, and why those records surfaced -- but no raw
    # identity facts and no token. The facts are already on the constituent record this event is
    # attached to, and the token is a credential-shaped value with no business meaning after the
    # request that spent it.
    def record_no_match_confirmation(constituent)
      return if @confirmed_no_match.blank?

      AuditEventService.log(
        action: 'paper_identity_no_match_confirmed',
        actor: @admin,
        auditable: constituent,
        metadata: {
          candidate_ids: @confirmed_no_match[:candidate_ids],
          candidate_count: @confirmed_no_match[:candidate_ids].size,
          reason_codes: @confirmed_no_match[:reason_codes]
        }
      )
    end

    def no_email_address?(scope = :constituent)
      paper_contact_flags(scope).no_email?
    end

    def no_phone_number?(scope = :constituent)
      paper_contact_flags(scope).no_phone?
    end

    def paper_contact_flags(scope)
      Applications::PaperContactFlags.new(params, scope: scope)
    end

    def track_email_backed_portal_created_user_ids(user_ids)
      Array(user_ids).each { |user_id| track_email_backed_portal_created_user_id(user_id) }
    end

    def track_email_backed_portal_created_user_id(user_id)
      @created_portal_user_ids << user_id.to_s if user_id.present?
    end

    def validate_no_active_application(user_type)
      return true unless @constituent.applications.blocking_new_submission.exists?

      error_message = case user_type
                      when 'dependent'
                        'This dependent already has an active or pending application.'
                      else
                        'This constituent already has an active or pending application.'
                      end
      add_error(error_message)
      false
    end

    def update_dependent_contact_info(dependent)
      attrs = params[:constituent]
      return true if attrs.blank?

      attrs = apply_dependent_contact_strategies!(attrs, dependent: dependent)
      return false if attrs.nil?

      updates = build_dependent_contact_updates(attrs)
      return true if updates.empty?

      if dependent.update(updates)
        Rails.logger.info "Updated contact info for dependent #{dependent.id}: #{updates.keys.join(', ')}"
        true
      else
        add_error("Failed to update dependent information: #{dependent.errors.full_messages.join(', ')}")
        false
      end
    rescue ActiveRecord::RecordInvalid => e
      add_error("Failed to update dependent information: #{e.record.errors.full_messages.join(', ')}")
      false
    end

    def update_existing_applicant_disability_info(user)
      attrs = params[:constituent]
      return true if attrs.blank?

      updates = build_disability_updates(attrs)
      return true if updates.empty?

      if user.update(updates)
        true
      else
        add_error("Failed to update applicant disability information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def build_disability_updates(attrs)
      APPLICANT_DISABILITY_FIELDS.each_with_object({}) do |field, updates|
        updates[field] = attrs[field] if attrs.key?(field)
      end
    end

    def build_dependent_contact_updates(attrs)
      data = attrs.with_indifferent_access
      updates = {}

      %i[email phone dependent_email dependent_phone].each do |field|
        updates[field] = data[field] if data.key?(field)
      end

      %i[
        physical_address_1 physical_address_2 city state zip_code
        locale communication_preference preferred_means_of_communication
        phone_type referral_source
      ].each do |field|
        updates[field] = data[field] if data[field].present?
      end

      updates
    end

    def apply_dependent_contact_strategies!(attrs, dependent: nil)
      guardian = guardian_for_dependent_contact_update
      return attrs.deep_dup if guardian.blank?
      return nil unless dependent_contact_instructions_consistent?(attrs)

      strategy_service = GuardianDependentManagementService.new(params)
      merged = merge_existing_dependent_contact(attrs, dependent)
      applied = strategy_service.apply_contact_strategies_for(guardian, merged)
      if applied
        applied
      else
        @errors.concat(strategy_service.errors)
        nil
      end
    end

    # "Use the guardian's email" unchecked, with the dependent's own email deliberately cleared, is
    # a contradiction rather than an instruction -- and resolving it silently has gone wrong in both
    # directions. Backfilling from the record undoes the clear while the re-rendered form still
    # shows blank, so an unchanged retry persists something staff cannot see. Letting the blank
    # through instead reaches `apply_email_strategy`'s guardian fallback, which mints a synthetic
    # primary identifier and moves delivery to the guardian.
    #
    # Neither is what was asked for, so it is refused with a message staff can act on. Keyed on the
    # field being *submitted* blank: absent means the checkbox disabled it, which is a real
    # instruction and still backfills below.
    def dependent_contact_instructions_consistent?(attrs)
      data = attrs.to_h.with_indifferent_access
      consistent = true

      { email: 'email address', phone: 'phone number' }.each do |kind, label|
        next unless params[:"#{kind}_strategy"].to_s == 'dependent'
        next unless data.key?(:"dependent_#{kind}") || data.key?(kind)
        next if data[:"dependent_#{kind}"].present? || data[kind].present?

        add_error("Enter the dependent's own #{label}, or select the option to use the guardian's " \
                  "#{label}. It cannot be blank while the dependent is set to use their own.")
        consistent = false
      end

      consistent
    end

    # Backfills an existing dependent's own contact from their record when the form supplied none.
    #
    # Deliberately keyed on blankness, not key presence. Key presence would make a cleared field
    # authoritative, and that is not a restoration change -- it is a contact policy change. A blank
    # dependent contact reaches `GuardianDependentManagementService#apply_email_strategy`, which
    # falls back to the guardian strategy and mints a synthetic
    # `dependent-<uuid>@system.matvulcan.local` primary identifier. Clearing the field would then
    # silently revoke the dependent's portal access and hand delivery to the guardian, while the
    # re-rendered form still showed "use guardian" unchecked beside an empty box.
    #
    # Honouring a deliberate clear is a real gap, but it belongs with that fallback -- refusing
    # blank-plus-dependent rather than converting it -- not here.
    def merge_existing_dependent_contact(attrs, dependent)
      data = attrs.deep_dup.with_indifferent_access
      return data unless dependent

      if data[:dependent_email].blank? && data[:email].blank?
        if dependent.dependent_email.present?
          data[:dependent_email] = dependent.dependent_email
        elsif dependent.real_email?
          data[:email] = dependent.email
          data[:dependent_email] = dependent.email
        end
      end

      if data[:dependent_phone].blank? && data[:phone].blank?
        if dependent.dependent_phone.present?
          data[:dependent_phone] = dependent.dependent_phone
        elsif dependent.real_phone?
          data[:phone] = dependent.phone
          data[:dependent_phone] = dependent.phone
        end
      end

      data
    end

    def guardian_for_dependent_contact_update
      @guardian_user_for_app || User.find_by(id: params[:guardian_id])
    end

    def update_existing_adult_contact_info(user)
      persist_adult_contact_updates!(user, params[:constituent])
    end

    def persist_adult_contact_updates!(user, constituent_attrs)
      return true if constituent_attrs.blank?

      flagged = paper_contact_flags(:constituent).apply_to(constituent_attrs)
      updates = build_adult_contact_updates(flagged)
      return true if updates.empty?

      changed_fields = contact_field_changes(user, updates)
      return true if changed_fields.empty?

      if user.update(updates)
        log_constituent_contact_updated!(user, changed_fields)
        true
      else
        add_error("Failed to update applicant information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def contact_field_changes(user, updates)
      updates.each_with_object({}) do |(key, new_val), changes|
        old_val = user.read_attribute(key)
        changes[key] = { from: old_val, to: new_val } if old_val.to_s != new_val.to_s
      end
    end

    def log_constituent_contact_updated!(user, changed_fields)
      AuditEventService.log(
        action: 'constituent_contact_updated',
        actor: @admin,
        auditable: user,
        metadata: {
          source: 'paper_application',
          changes: changed_fields
        }
      )
    end

    def build_adult_contact_updates(attrs)
      updates = build_contact_updates(attrs, fields: ADULT_CONTACT_FIELDS)
      paper_contact_flags(:constituent).apply_clear_flags_to(updates)
    end

    def build_contact_updates(attrs, fields:, aliases: {})
      updates = {}
      fields.each { |f| updates[f] = attrs[f] if attrs[f].present? }
      aliases.each { |src, dest| updates[dest] = attrs[src] if attrs[src].present? }
      updates
    end

    def create_application
      Current.paper_context = true

      application_attrs = params[:application]
      return add_error('Application params missing') if application_attrs.blank?

      return false unless validate_income_threshold(application_attrs)

      @constituent.reload
      build_and_save_application(application_attrs)
    ensure
      Current.paper_context = nil
    end

    def validate_income_threshold(application_attrs)
      return true if @skip_income_validation
      return true unless FeatureFlag.income_proof_required?
      return true unless income_proof_action_requires_income_validation?

      household_size = application_attrs[:household_size]
      annual_income = application_attrs[:annual_income]

      threshold_service = IncomeThresholdCalculationService.new(household_size)
      result = threshold_service.call

      return false unless result.success?

      threshold = result.data[:threshold]
      return true if annual_income.to_i <= threshold

      add_error('Income exceeds the maximum threshold for the household size.')
      false
    end

    def income_proof_action_requires_income_validation?
      params[:income_proof_action].to_s.in?(%w[accept approved])
    end

    def build_and_save_application(application_attrs)
      @application = Application.new(application_attrs)
      @application.user = @constituent
      @application.managing_guardian = @guardian_user_for_app
      @application.submission_method = :paper
      @application.application_date = Time.current

      # Set appropriate status based on what's missing
      @application.status = determine_initial_status

      return true if @application.save

      add_error("Failed to create application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def determine_initial_status
      return :awaiting_proof if params[:no_medical_provider_information]

      income_action = params[:income_proof_action]
      residency_action = params[:residency_proof_action]

      # Only consider income action when income collection is enabled
      if FeatureFlag.income_proof_required?
        return :awaiting_proof if income_action.in?(%w[none reject]) || residency_action.in?(%w[none reject])
      elsif residency_action.in?(%w[none reject])
        return :awaiting_proof
      end

      :in_progress
    end

    # Update application attributes within paper context
    # only if params[:application] is present
    def update_application_attributes
      application_attrs = params[:application]
      return true if application_attrs.blank?

      # Update attributes - model callback automatically sets paper context
      return true if @application.update(application_attrs)

      add_error("Failed to update application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def reconcile_after_paper_write(trigger)
      @application.reload.reconcile_workflow_state!(actor: @admin, trigger: trigger)
    rescue StandardError => e
      log_error(e, "Workflow reconciliation failed after paper application #{@application&.id} #{trigger}")
      @reconciliation_note = 'Workflow status update failed -- please verify this application status and advance it manually if needed.'
    end

    def process_proof_uploads
      Current.paper_context = true

      proof_types = %i[income residency id medical_certification]
      proof_types -= %i[income] unless @application.income_proof_required?

      proof_types.each do |proof_type|
        return false unless process_proof(proof_type)
      end

      true
    ensure
      Current.paper_context = nil
    end

    def process_proof(type)
      # Handle medical_certification naming convention
      action_key = type == :medical_certification ? "#{type}_action" : "#{type}_proof_action"
      action = params[action_key] || params[action_key.to_sym]

      return true unless %w[upload_only accept reject approved rejected not_requested].include?(action)

      case action
      when 'upload_only'
        process_upload_only_proof(type)
      when 'accept', 'approved'
        process_accept_proof(type)
      when 'reject', 'rejected'
        process_reject_proof(type)
      when 'not_requested'
        true
      end
    end

    def process_upload_only_proof(type)
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"
      blob_or_file = params[file_key].presence || params[signed_id_key].presence

      return add_error("Please upload a file for #{proof_upload_label(type)} before sending it for review") if blob_or_file.blank?

      result = if type == :medical_certification
                 MedicalCertificationAttachmentService.attach_certification(
                   application: @application,
                   blob_or_file: blob_or_file,
                   status: :received,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               else
                 ProofAttachmentService.attach_proof(
                   application: @application,
                   proof_type: type,
                   blob_or_file: blob_or_file,
                   status: :not_reviewed,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               end

      unless result[:success]
        add_error("Error processing #{proof_upload_label(type)}: #{result[:error]&.message}")
        return false
      end

      true
    end

    def proof_upload_label(type)
      type == :medical_certification ? 'medical certification' : "#{type} proof"
    end

    def process_accept_proof(type)
      # Handle medical_certification naming convention
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"

      file_param = params[file_key]
      signed_id_param = params[signed_id_key]

      # Check if we have a valid file or signed_id
      # file_param can be:
      # - An uploaded file (ActionDispatch::Http::UploadedFile)
      # - A file-like object (responds to :read)
      # - A signed blob ID string (String)
      # signed_id_param should be a non-empty string if present
      file_valid = file_param.present? && (
        file_param.respond_to?(:read) ||
        file_param.is_a?(ActionDispatch::Http::UploadedFile) ||
        (file_param.is_a?(String) && !file_param.empty?)
      )
      signed_id_valid = signed_id_param.present? && signed_id_param.is_a?(String) && !signed_id_param.empty?

      file_present = file_valid || signed_id_valid

      # Approval requires an attachment in all contexts. Only rejections may proceed without files.
      return add_error("Please upload a file for #{type} proof before approving") unless file_present

      attach_and_approve_proof(type)
    end

    def attach_and_approve_proof(type)
      # Handle medical_certification naming convention
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"

      blob_or_file = params[file_key].presence || params[signed_id_key].presence

      # Route medical certifications to the correct service
      result = if type == :medical_certification
                 MedicalCertificationAttachmentService.attach_certification(
                   application: @application,
                   blob_or_file: blob_or_file,
                   status: :approved,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               else
                 ProofAttachmentService.attach_proof(
                   application: @application,
                   proof_type: type,
                   blob_or_file: blob_or_file,
                   status: :approved,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               end

      unless result[:success]
        add_error("Error processing #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
    end

    def process_reject_proof(type)
      reason_key        = type == :medical_certification ? "#{type}_rejection_reason" : "#{type}_proof_rejection_reason"
      custom_reason_key = type == :medical_certification ? "#{type}_custom_rejection_reason" : "#{type}_proof_custom_rejection_reason"
      notes_key         = type == :medical_certification ? "#{type}_rejection_notes" : "#{type}_proof_rejection_notes"
      selected_reason   = fetch_param(reason_key).to_s
      custom_reason     = fetch_param(custom_reason_key).to_s.strip
      legacy_notes      = fetch_param(notes_key).to_s.strip
      custom_reason     = legacy_notes if custom_reason.blank? && legacy_notes.present?

      result = if type == :medical_certification
                 reject_medical_certification(
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               else
                 reject_non_medical_proof(
                   type: type,
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               end

      unless result[:success]
        add_error("Error rejecting #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
    end

    def resolve_rejection_reason_value(selected_reason:, custom_reason:)
      return selected_reason unless selected_reason == 'other'
      return 'Other' if custom_reason.blank?

      custom_reason
    end

    def reject_non_medical_proof(type:, selected_reason:, custom_reason:, notes:)
      resolved_reason = resolve_rejection_reason_value(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      ProofAttachmentService.reject_proof_without_attachment(
        application: @application,
        proof_type: type,
        admin: @admin,
        reason: resolved_reason,
        notes: notes,
        submission_method: :paper,
        metadata: {}
      )
    end

    def resolve_medical_rejection_reason_payload(selected_reason:, custom_reason:)
      if selected_reason.present? && %w[none_provided other].exclude?(selected_reason)
        resolved_reason = RejectionReason.resolve_text(
          code: selected_reason,
          proof_type: 'medical_certification',
          fallback: selected_reason
        )

        return { reason: resolved_reason, reason_code: selected_reason }
      end

      return { reason: 'none_provided', reason_code: nil } if selected_reason == 'none_provided'
      return { reason: 'Other', reason_code: nil } if custom_reason.blank?

      { reason: custom_reason, reason_code: nil }
    end

    def fetch_param(key)
      params[key] || params[key.to_sym]
    end

    def reject_medical_certification(selected_reason:, custom_reason:, notes:)
      if medical_certification_reviewer_path?(selected_reason)
        reject_medical_certification_via_reviewer(
          selected_reason: selected_reason,
          custom_reason: custom_reason,
          notes: notes
        )
      else
        reject_medical_certification_directly(
          selected_reason: selected_reason,
          custom_reason: custom_reason,
          notes: notes
        )
      end
    end

    def medical_certification_reviewer_path?(selected_reason)
      selected_reason != 'none_provided' && medical_provider_notification_available?
    end

    def medical_provider_notification_available?
      @application.medical_provider_name.present? &&
        (@application.medical_provider_email.present? || @application.medical_provider_fax.present?)
    end

    def reject_medical_certification_via_reviewer(selected_reason:, custom_reason:, notes:)
      reason_payload = resolve_medical_rejection_reason_payload(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      reviewer_result = Applications::MedicalCertificationReviewer.new(@application, @admin).reject(
        rejection_reason: reason_payload[:reason],
        notes: notes,
        rejection_reason_code: reason_payload[:reason_code]
      )

      return { success: true } if reviewer_result.success?

      { success: false, error: StandardError.new(reviewer_result.message) }
    end

    def reject_medical_certification_directly(selected_reason:, custom_reason:, notes:)
      reason_payload = resolve_medical_rejection_reason_payload(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      MedicalCertificationAttachmentService.reject_certification(
        application: @application,
        admin: @admin,
        reason: reason_payload[:reason],
        notes: notes,
        reason_code: reason_payload[:reason_code],
        submission_method: :paper,
        metadata: {}
      )
    end

    def log_proof_submission(type, has_attachment)
      AuditEventService.log(
        action: 'proof_submitted',
        actor: @admin,
        auditable: @application,
        metadata: {
          proof_type: type.to_s,
          submission_method: 'paper',
          status: 'approved',
          has_attachment: has_attachment
        }
      )
    end

    def send_notifications
      send_medical_certification_not_provided_notice
      send_account_creation_notifications
    end

    # Automatically sends a provider info secure form to the constituent/guardian
    # when an admin creates a paper application without certifying professional info.
    #
    # Failure stays non-blocking -- the application is already saved and the admin can send the form
    # manually -- but it is reported through the post-creation wrapper rather than swallowed here.
    # Catching its own errors and turning a failed result into a note meant this step alone produced
    # no named warning and no `application_post_creation_step_failed` event, so the one follow-up
    # most likely to fail was the one least visible afterwards.
    def request_provider_info_if_missing
      return unless params[:no_medical_provider_information]
      return if @application.medical_certification_status_approved?

      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: @admin
      ).call

      return if result.success?

      raise PostCreationStepFailure,
            "It could not be sent automatically: #{result.message} You can send it from the application page."
    rescue PostCreationStepFailure
      raise
    rescue StandardError
      # A raised failure is no less actionable than a returned one -- staff still need telling that
      # they can send the form by hand. Re-raised as the typed error so the wrapper keeps that
      # guidance; `raise` inside a rescue records the original as this exception's `cause`, which
      # `run_post_creation_step` unwraps for the log and the audit event.
      raise PostCreationStepFailure,
            'It could not be sent automatically. You can send it from the application page.'
    end

    # Income/residency/id proof rejections are delivered through ProofReview ->
    # Applications::RequestProofResubmission, which owns the secure resubmission flow.
    # The only constituent-facing rejection notice still sent directly from paper intake
    # is the "medical certification not provided" notice, which has no resubmission form.
    def send_medical_certification_not_provided_notice
      not_provided = @application.proof_reviews.reload.rejections.find_by(
        proof_type: :medical_certification,
        rejection_reason_code: 'none_provided'
      )
      return unless not_provided

      NotificationService.create_and_deliver!(
        type: 'medical_certification_not_provided',
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        channel: @constituent.communication_preference.to_sym
      )
    end

    def send_account_creation_notifications
      return unless send_account_created_notice?

      new_user_accounts.each do |user|
        next unless user.email_backed_public_portal_account?

        append_account_access_warning(user) if quick_created_portal_user?(user)

        NotificationService.create_and_deliver!(
          type: 'account_created',
          recipient: user,
          actor: @admin,
          notifiable: @application,
          metadata: {
            template_variables: account_creation_template_variables(user)
          },
          channel: user.communication_preference.to_sym
        )
      end
    end

    # Account-created notices (and their printed letters) are voucher-only.
    # Equipment-scope applicants and cert signers should use secure temporary
    # form links for proof/cert uploads; announcing an account they cannot create
    # or log in to would be misleading.
    def send_account_created_notice?
      FeatureFlag.enabled?(:vouchers_enabled)
    end

    def append_proof_resubmission_delivery_warnings
      @application.proof_reviews.rejections
                  .where(proof_type: ProofReview::REVIEWABLE_PROOF_TYPES)
                  .find_each do |review|
        next if Applications::RequestProofResubmission.delivery_confirmed_for_review?(review)

        note = "#{review.proof_type.to_s.humanize} proof resubmission form could not be automatically sent. " \
               'You can send it from the application page.'
        @reconciliation_note = [@reconciliation_note, note].compact.join(' ')
      end
    end

    def append_account_access_warning(user)
      note = "No temporary portal password is retained for #{user.full_name}. " \
             'Use the existing account access link flow if they need help signing in.'
      @reconciliation_note = [@reconciliation_note, note].compact.join(' ')
    end

    def new_user_accounts
      [@guardian_user_for_app, @constituent].compact.uniq.select do |user|
        user.present? && account_created_notice_candidate?(user)
      end
    end

    def account_created_notice_candidate?(user)
      return false unless user.email_backed_public_portal_account?
      return false unless account_access_instructions_deliverable?(user)

      @created_portal_user_ids.include?(user.id.to_s) || quick_created_portal_user?(user)
    end

    def account_access_instructions_deliverable?(user)
      user.real_email? || user.sms_capable_phone?
    end

    def quick_created_portal_user?(user)
      @quick_created_portal_user_ids.include?(user.id.to_s)
    end

    def account_creation_template_variables(user)
      {
        constituent_first_name: user.first_name,
        support_email: Policy.get('support_email') || 'mat.program1@maryland.gov',
        program_website_url: ProgramContact.website_url
      }
    end

    def attributes_present?(attrs)
      attrs.present? && attrs.values.any?(&:present?)
    end

    def add_error(message)
      @errors << message
      false
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n") if exception.backtrace
    end
  end
  # rubocop:enable Metrics/ClassLength
end
