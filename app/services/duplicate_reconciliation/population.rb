# frozen_string_literal: true

module DuplicateReconciliation
  class Population
    ACTIVE_APPLICATION_STATUSES = %w[in_progress awaiting_proof reminder_sent awaiting_dcf].freeze
    UNRESOLVED_STATES = %i[unreviewed open_reconciliation].freeze

    Member = Data.define(
      :id,
      :name,
      :real_email,
      :real_phone,
      :application_summary,
      :needs_duplicate_review
    ) do
      def self.from_user(user, application_summary:)
        new(
          id: user.id,
          name: user.full_name,
          real_email: user.real_email?,
          real_phone: user.real_phone?,
          application_summary: application_summary,
          needs_duplicate_review: user.needs_duplicate_review?
        )
      end
    end

    Pair = Data.define(:first, :second, :state, :review_case_id) do
      def ids
        [first.id, second.id]
      end

      def unresolved?
        UNRESOLVED_STATES.include?(state)
      end
    end

    def pairs(include_historical: false)
      current_keys = current_pair_keys
      cases_by_pair = reconciliation_cases_by_pair
      users_by_id = load_users(current_keys.flatten)
      application_summaries = load_application_summaries(users_by_id.keys)
      current_pairs = current_keys.filter_map do |ids|
        build_current_pair(ids, users_by_id:, application_summaries:, cases: cases_by_pair.fetch(ids, []))
      end

      return current_pairs unless include_historical

      historical_keys = cases_by_pair.keys - current_keys
      historical_users = load_users(historical_keys.flatten, eligible_only: false)
      historical_application_summaries = load_application_summaries(historical_users.keys)
      historical_pairs = historical_keys.filter_map do |ids|
        build_historical_pair(
          ids,
          users_by_id: historical_users,
          application_summaries: historical_application_summaries,
          cases: cases_by_pair.fetch(ids)
        )
      end

      (current_pairs + historical_pairs).sort_by(&:ids)
    end

    def pair_for_ids(first_id, second_id)
      ids = canonical_ids(first_id, second_id)
      return if ids.blank?

      users_by_id = load_users(ids, eligible_only: false)
      return unless users_by_id.size == 2

      users = ids.map { |id| users_by_id.fetch(id) }
      cases = cases_for_pair(ids)
      application_summaries = load_application_summaries(ids)
      if current_match?(*users)
        build_current_pair(ids, users_by_id:, application_summaries:, cases: cases)
      elsif cases.any?
        build_historical_pair(ids, users_by_id:, application_summaries:, cases: cases)
      end
    end

    def unresolved_for_user?(user)
      return false unless eligible_user?(user)

      matching_user_ids(user).any? do |candidate_id|
        pair_for_ids(user.id, candidate_id)&.unresolved?
      end
    end

    def current_match?(first_user, second_user)
      return false unless eligible_user?(first_user) && eligible_user?(second_user)

      Users::Constituent.find_duplicates(
        first_user.first_name,
        first_user.last_name,
        first_user.date_of_birth
      ).exists?(id: second_user.id)
    end

    def self.strict_case_pair_ids(review_case, candidates: nil)
      return unless review_case.post_import_reconciliation?
      return unless Array(review_case.metadata['reason_codes']).map(&:to_s) == ['name_dob']

      candidate_rows = candidates || review_case.duplicate_review_case_candidates.to_a
      return unless candidate_rows.one?

      candidate = candidate_rows.first
      return unless candidate.match_reason == 'name_dob'

      subject_id = review_case.subject_user_id
      candidate_id = candidate.candidate_user_id
      return if subject_id.blank? || candidate_id.blank? || subject_id >= candidate_id

      [subject_id, candidate_id]
    end

    private

    def eligible_scope
      Users::Constituent.where(merged_into_user_id: nil)
                        .where(status: [nil, User.statuses.fetch('active')])
                        .where.not(first_name: [nil, ''])
                        .where.not(last_name: [nil, ''])
                        .where.not(date_of_birth: nil)
    end

    def eligible_user?(user)
      user.is_a?(Users::Constituent) && user.public_login_active? &&
        user.first_name.present? && user.last_name.present? && user.date_of_birth.is_a?(Date)
    rescue ActiveRecord::Encryption::Errors::Decryption
      false
    end

    def current_pair_keys
      eligible_scope
        .group(Arel.sql('LOWER(users.first_name)'), Arel.sql('LOWER(users.last_name)'), :date_of_birth)
        .having('COUNT(*) > 1')
        .pluck(Arel.sql('ARRAY_AGG(users.id ORDER BY users.id)'))
        .flat_map { |ids| ids.map(&:to_i).combination(2).to_a }
        .sort
    end

    def matching_user_ids(user)
      duplicate_ids = Users::Constituent.find_duplicates(
        user.first_name,
        user.last_name,
        user.date_of_birth
      ).where.not(id: user.id).select(:id)

      eligible_scope.where(id: duplicate_ids).order(:id).pluck(:id)
    end

    def reconciliation_cases_by_pair
      reconciliation_cases.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |review_case, indexed|
        ids = self.class.strict_case_pair_ids(review_case)
        indexed[ids] << review_case if ids
      end
    end

    def cases_for_pair(ids)
      subject_id, candidate_id = ids
      matching_cases = DuplicateReviewCase.where(
        source: :post_import_reconciliation,
        subject_user_id: subject_id
      )
      matching_case_ids = matching_cases.joins(:duplicate_review_case_candidates)
      matching_case_ids = matching_case_ids.where(
        duplicate_review_case_candidates: { candidate_user_id: candidate_id }
      ).select(:id)

      DuplicateReviewCase.where(id: matching_case_ids)
                         .includes(:duplicate_review_case_candidates)
                         .order(:id)
                         .select { |review_case| self.class.strict_case_pair_ids(review_case) == ids }
    end

    def reconciliation_cases
      @reconciliation_cases ||=
        DuplicateReviewCase.where(source: :post_import_reconciliation)
                           .includes(:duplicate_review_case_candidates)
                           .order(:id)
                           .to_a
    end

    def load_users(ids, eligible_only: true)
      return {} if ids.empty?

      scope = eligible_only ? eligible_scope : Users::Constituent.all
      scope.where(id: ids.uniq).index_by(&:id)
    end

    def load_application_summaries(user_ids)
      Application.where(
        user_id: user_ids,
        status: ACTIVE_APPLICATION_STATUSES + %w[approved]
      ).pluck(:user_id, :status).each_with_object({}) do |(user_id, status), summaries|
        if ACTIVE_APPLICATION_STATUSES.include?(status)
          summaries[user_id] = 'active'
        elsif status == 'approved'
          summaries[user_id] ||= 'approved-only'
        end
      end
    end

    def build_current_pair(ids, users_by_id:, application_summaries:, cases:)
      users = users_for(ids, users_by_id)
      return unless users&.all? { |user| eligible_user?(user) }

      state, review_case = current_state(cases)
      build_pair(users, application_summaries:, state:, review_case:)
    end

    def build_historical_pair(ids, users_by_id:, application_summaries:, cases:)
      users = users_for(ids, users_by_id)
      return unless users

      state, review_case = historical_state(users, cases)
      build_pair(users, application_summaries:, state:, review_case:)
    end

    def users_for(ids, users_by_id)
      users = ids.map { |id| users_by_id[id] }
      users if users.all?
    end

    def build_pair(users, application_summaries:, state:, review_case:)
      Pair.new(
        first: Member.from_user(
          users.first,
          application_summary: application_summaries.fetch(users.first.id, 'none')
        ),
        second: Member.from_user(
          users.second,
          application_summary: application_summaries.fetch(users.second.id, 'none')
        ),
        state: state,
        review_case_id: review_case&.id
      )
    end

    def current_state(cases)
      open_case = cases.rfind(&:open?)
      return [:open_reconciliation, open_case] if open_case

      different_case = cases.rfind do |review_case|
        review_case.resolved? && review_case.resolution_determination == 'keep_separate'
      end
      return [:confirmed_different, different_case] if different_case

      merged_case = cases.rfind do |review_case|
        review_case.resolved_merged? && review_case.resolution_determination == 'same_person_confirmed'
      end
      return [:merged_retired, merged_case] if merged_case

      return [:stale_ineligible, cases.last] if cases.any?

      [:unreviewed, nil]
    end

    def historical_state(users, cases)
      merged_case = cases.rfind(&:resolved_merged?)
      return [:merged_retired, merged_case || cases.last] if merged_case || users.any?(&:merged?)

      [:stale_ineligible, cases.last]
    end

    def canonical_ids(first_id, second_id)
      ids = [Integer(first_id, exception: false), Integer(second_id, exception: false)].compact.uniq.sort
      ids if ids.size == 2
    end
  end
end
