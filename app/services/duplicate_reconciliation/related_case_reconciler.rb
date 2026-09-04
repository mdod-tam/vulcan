# frozen_string_literal: true

module DuplicateReconciliation
  # Reconciles other open exact-pair post-import cases when one participant is
  # retired by a same-person merge. The selected merge case is handled by
  # Users::DuplicateMergeService; this collaborator only preserves still-open work.
  class RelatedCaseReconciler
    Action = Data.define(:type, :review_case, :candidate_row, :old_pair_ids, :target_pair_ids, :replacement_case)

    attr_reader :error, :affected_user_ids

    # rubocop:disable Metrics/ParameterLists -- explicit merge-time inventory contract
    def initialize(selected_case:, canonical_user:, duplicate_user:, actor:, cases:, candidate_rows:, locked_users:)
      @selected_case = selected_case
      @canonical_user = canonical_user
      @duplicate_user = duplicate_user
      @actor = actor
      @cases = Array(cases)
      @candidate_rows_by_case_id = Array(candidate_rows).group_by(&:duplicate_review_case_id)
      @locked_users = locked_users
      @actions = []
      @affected_user_ids = []
      build
    end
    # rubocop:enable Metrics/ParameterLists

    def valid?
      error.blank?
    end

    def apply!
      raise ArgumentError, error unless valid?

      counts = Hash.new(0)
      @actions.each do |action|
        if action.type == :repoint
          repoint!(action)
          counts[:related_post_import_cases_repointed] += 1
        else
          supersede!(action)
          counts[:related_post_import_cases_superseded] += 1
        end
      end
      counts
    end

    private

    def build
      target_cases = existing_target_cases

      related_cases.each do |review_case|
        build_action(review_case, target_cases)
        break if error
      end

      @affected_user_ids = @affected_user_ids.uniq
    end

    def build_action(review_case, target_cases)
      return unless participant_ids(review_case).include?(@duplicate_user.id)

      pair_ids = strict_pair_ids(review_case)
      return unsafe_related_case! unless pair_ids

      target_ids = pair_ids.map { |id| id == @duplicate_user.id ? @canonical_user.id : id }.uniq.sort
      @affected_user_ids.concat(pair_ids + target_ids)

      return add_action(:supersede, review_case, pair_ids, target_ids, @selected_case) if target_ids.one?

      target_users = locked_target_users(target_ids)
      return unless target_users

      build_pair_action(review_case, pair_ids, target_ids, target_users, target_cases)
    end

    def build_pair_action(review_case, pair_ids, target_ids, target_users, target_cases)
      replacement = target_cases[target_ids] || resolved_target_case(target_ids)
      if replacement
        add_action(:supersede, review_case, pair_ids, target_ids, replacement)
      elsif current_supported_pair?(*target_users)
        add_action(:repoint, review_case, pair_ids, target_ids, nil)
        target_cases[target_ids] = review_case
      else
        add_action(:supersede, review_case, pair_ids, target_ids, nil)
      end
    end

    def locked_target_users(target_ids)
      users = target_ids.map { |id| @locked_users[id] }
      return users if users.none?(&:nil?)

      changed_participant!
      nil
    end

    def unsafe_related_case!
      @error = 'Another open duplicate review case involving the retiring record cannot be safely carried forward; resolve it before merging'
    end

    def changed_participant!
      @error = 'A related duplicate-review participant changed while the merge was being prepared; reload and try again'
    end

    def add_action(type, review_case, old_pair_ids, target_pair_ids, replacement_case)
      @actions << action(type, review_case, old_pair_ids, target_pair_ids, replacement_case)
    end

    def related_cases
      @cases.reject { |review_case| review_case.id == @selected_case.id }
    end

    def existing_target_cases
      related_cases.each_with_object({}) do |review_case, indexed|
        ids = strict_pair_ids(review_case)
        next if ids.blank? || ids.include?(@duplicate_user.id)

        indexed[ids] ||= review_case
      end
    end

    def strict_pair_ids(review_case)
      DuplicateReconciliation::Population.strict_case_pair_ids(
        review_case,
        candidates: @candidate_rows_by_case_id.fetch(review_case.id, [])
      )
    end

    def participant_ids(review_case)
      [review_case.subject_user_id,
       *@candidate_rows_by_case_id.fetch(review_case.id, []).map(&:candidate_user_id)].compact.uniq
    end

    def current_supported_pair?(*users)
      users.all? { |user| user.is_a?(Users::Constituent) && user.public_login_active? } &&
        Population.new.current_match?(*users)
    end

    def resolved_target_case(target_ids)
      pair = Population.new.pair_for_ids(*target_ids)
      return unless pair&.state == :confirmed_different

      DuplicateReviewCase.find_by(id: pair.review_case_id)
    end

    def action(type, review_case, old_pair_ids, target_pair_ids, replacement_case)
      Action.new(
        type: type,
        review_case: review_case,
        candidate_row: @candidate_rows_by_case_id.fetch(review_case.id).sole,
        old_pair_ids: old_pair_ids,
        target_pair_ids: target_pair_ids,
        replacement_case: replacement_case
      )
    end

    def repoint!(action)
      subject_id, candidate_id = action.target_pair_ids
      action.review_case.update!(
        subject_user_id: subject_id,
        deduplication_key: DuplicateReviewCases::CreateService.deduplication_key_for(
          source: :post_import_reconciliation,
          subject_user_id: subject_id,
          reason_codes: ['name_dob'],
          candidate_user_ids: [candidate_id]
        )
      )
      action.candidate_row.update!(candidate_user_id: candidate_id)

      AuditEventService.log(
        action: 'duplicate_review_case_pair_repointed',
        actor: @actor,
        auditable: @canonical_user,
        metadata: {
          duplicate_review_case_id: action.review_case.id,
          superseding_merge_case_id: @selected_case.id,
          previous_pair_ids: action.old_pair_ids,
          current_pair_ids: action.target_pair_ids
        }
      )
    end

    def supersede!(action)
      replacement_case_id = action.replacement_case&.id
      action.review_case.update!(
        status: :resolved_superseded,
        resolution_determination: :superseded_by_merge,
        resolution_rationale: supersession_rationale(replacement_case_id),
        resolution_metadata: {
          'canonical_user_id' => @canonical_user.id,
          'merged_user_id' => @duplicate_user.id,
          'replacement_case_id' => replacement_case_id,
          'superseding_merge_case_id' => @selected_case.id
        }.compact,
        resolved_by: @actor,
        resolved_at: Time.current
      )

      AuditEventService.log(
        action: 'duplicate_review_case_superseded',
        actor: @actor,
        auditable: @canonical_user,
        metadata: {
          duplicate_review_case_id: action.review_case.id,
          superseding_merge_case_id: @selected_case.id,
          replacement_case_id: replacement_case_id
        }.compact
      )
    end

    def supersession_rationale(replacement_case_id)
      return "Superseded by a same-person merge; review continues in duplicate review case ##{replacement_case_id}." if replacement_case_id

      'Superseded by a same-person merge; the resulting records no longer form a supported post-import pair.'
    end
  end
end
