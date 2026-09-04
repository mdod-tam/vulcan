# frozen_string_literal: true

module DuplicateReviewCases
  # Clears a legacy needs_duplicate_review flag directly (not through a case resolution).
  # An open case owns the flag, so this refuses when one exists for the user as subject or
  # candidate -- the case must be resolved instead.
  class ClearFlagService < BaseService
    class OpenCaseExistsError < StandardError; end
    class UnresolvedPairExistsError < StandardError; end
    class IneligibleUserError < StandardError; end

    def initialize(user:, actor:, rationale:)
      super()
      @user = user
      @actor = actor
      @rationale = rationale.to_s.strip
    end

    def call
      return failure('A rationale is required to clear a review flag.') if @rationale.blank?
      return failure('An active admin actor is required to clear a review flag.') unless @actor&.persisted?

      ActiveRecord::Base.transaction do
        # Lock the subject before checking for an open case, so a concurrent case creation
        # or resolution can't land between the check and the update below. Uses the same
        # User.lock_for_merge_integrity! ordering as every other writer that touches this
        # subject, so it can never deadlock against them.
        locked_users = User.lock_for_merge_integrity!(@user, @actor)
        locked_user = locked_users.fetch(@user.id)
        @actor = locked_users.fetch(@actor.id)

        # A lock does not validate a stale decision: if a merge retired this user (or it
        # otherwise became suspended/inactive) while this request waited for the lock, the
        # pre-lock instance this service was constructed with is stale. Without this check,
        # the update below would trip the merged-record immutability guard and raise
        # ActiveRecord::RecordInvalid as an uncaught exception (a 500), instead of the clean
        # failure result every other blocker here returns.
        raise IneligibleUserError unless locked_user.public_login_active?
        raise IneligibleActorError unless @actor.admin? && @actor.public_login_active?
        raise OpenCaseExistsError if DuplicateReviewCase.open_cases.for_participant(locked_user).exists?
        raise UnresolvedPairExistsError if DuplicateReconciliation::Population.new.unresolved_for_user?(locked_user)

        locked_user.update!(needs_duplicate_review: false)
        AuditEventService.log(
          action: 'duplicate_review_flag_cleared',
          actor: @actor,
          auditable: locked_user,
          metadata: { user_id: locked_user.id, rationale: @rationale }
        )
      end

      success('Review flag cleared.')
    rescue OpenCaseExistsError
      failure('This record has an open review case; resolve the case instead of clearing the flag.')
    rescue UnresolvedPairExistsError
      failure('This record still has an unresolved matching pair; review the pair instead of clearing the flag.')
    rescue IneligibleUserError
      failure('This record is no longer an eligible active record.')
    rescue IneligibleActorError
      failure('An active admin actor is required to clear a review flag.')
    end

    class IneligibleActorError < StandardError; end
  end
end
