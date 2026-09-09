# frozen_string_literal: true

module DuplicateReconciliation
  class ReviewPairService < BaseService
    class PairError < StandardError; end

    def initialize(actor:, first_user_id:, second_user_id:)
      super()
      @actor = actor
      @pair_ids = canonical_ids(first_user_id, second_user_id)
    end

    def call
      return failure('Select two different constituent records to review.') unless @pair_ids
      return failure('An active admin actor is required.') unless @actor&.persisted?

      review_case = nil
      idempotent = false

      ActiveRecord::Base.transaction do
        lock_and_requalify!
        requalified_pair!
        result = create_or_reuse_case!
        review_case = result.data.fetch(:duplicate_review_case)
        idempotent = result.data.fetch(:idempotent)
        @pair_users.each { |user| user.update!(needs_duplicate_review: true) unless user.needs_duplicate_review? }
      end

      success(
        'Duplicate pair is ready for review.',
        { duplicate_review_case: review_case, idempotent: idempotent }
      )
    rescue PairError, ActiveRecord::RecordNotFound => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence.presence || 'The pair could not be opened for review.')
    end

    private

    def lock_and_requalify!
      locked = User.lock_for_merge_integrity!(@actor.id, *@pair_ids)
      @actor = locked.fetch(@actor.id)
      raise PairError, 'An active admin actor is required.' unless @actor.admin? && @actor.public_login_active?

      @pair_users = @pair_ids.map { |id| locked.fetch(id) }
      return if @pair_users.all? { |user| user.is_a?(Users::Constituent) && user.public_login_active? }

      raise PairError, 'Both records must still be active, eligible constituents.'
    end

    def requalified_pair!
      pair = Population.new.pair_for_ids(*@pair_ids)
      raise PairError, 'These records no longer form a current supported name-and-date-of-birth pair.' unless pair
      raise PairError, 'This pair has already been resolved.' if %i[confirmed_different merged_retired].include?(pair.state)
      raise PairError, 'This pair is stale or no longer eligible.' if pair.state == :stale_ineligible
      raise PairError, 'These records already have an open duplicate review case.' if
        pair.state != :open_reconciliation && another_open_case_for_pair?

      pair
    end

    def another_open_case_for_pair?
      first_id, second_id = @pair_ids
      DuplicateReviewCase.open_cases
                         .joins(:duplicate_review_case_candidates)
                         .where.not(source: :post_import_reconciliation)
                         .exists?(
                           [
                             '(duplicate_review_cases.subject_user_id = :first_id AND ' \
                             'duplicate_review_case_candidates.candidate_user_id = :second_id) OR ' \
                             '(duplicate_review_cases.subject_user_id = :second_id AND ' \
                             'duplicate_review_case_candidates.candidate_user_id = :first_id)',
                             { first_id: first_id, second_id: second_id }
                           ]
                         )
    end

    def create_or_reuse_case!
      result = DuplicateReviewCases::CreateService.new(
        source: :post_import_reconciliation,
        subject_user: @pair_users.first,
        actor: @actor,
        reason_codes: ['name_dob'],
        candidates: [
          DuplicateReviewCases::CreateService::CandidateInput.new(@pair_users.second, 'name_dob', {})
        ]
      ).call
      raise PairError, result.message unless result.success?

      result
    end

    def canonical_ids(first_id, second_id)
      ids = [Integer(first_id, exception: false), Integer(second_id, exception: false)].compact.uniq.sort
      ids if ids.size == 2
    end
  end
end
