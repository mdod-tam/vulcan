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
      historical_keys = include_historical ? cases_by_pair.keys - current_keys : []
      users_by_id = load_users((current_keys + historical_keys).flatten, eligible_only: !include_historical)
      members_by_id = load_members(users_by_id)
      current_pairs = current_keys.filter_map do |ids|
        build_current_pair(ids, users_by_id:, members_by_id:, cases: cases_by_pair.fetch(ids, []))
      end

      return current_pairs unless include_historical

      historical_pairs = historical_keys.filter_map do |ids|
        build_historical_pair(
          ids,
          users_by_id:,
          members_by_id:,
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
      members_by_id = load_members(users_by_id)
      if current_match?(*users)
        build_current_pair(ids, users_by_id:, members_by_id:, cases: cases)
      elsif cases.any?
        build_historical_pair(ids, users_by_id:, members_by_id:, cases: cases)
      end
    end

    # Select a page of name/DOB clusters before loading their members or expanding pairs.
    # A cluster is only a browsing aid; review authority remains one exact pair.
    def unreviewed_groups
      representatives = eligible_scope
                        .group(Arel.sql('LOWER(users.first_name)'), Arel.sql('LOWER(users.last_name)'), :date_of_birth)
                        .having('COUNT(*) > 1')
                        .select(Arel.sql('MIN(users.id)'))
      remaining_pairs = unreviewed_pair_scope
                        .where(same_match_key(Arel::Table.new(:pair_first), User.arel_table))
                        .reselect('1')

      eligible_scope.where(id: representatives)
                    .where(remaining_pairs.arel.exists)
                    .order(:id)
    end

    # The returned relation is paginated by the caller before any Pair/Member allocation.
    def unreviewed_pairs_for_group(group_id)
      selected_group = User.unscoped.where(id: group_id)
                           .where(same_match_key(Arel::Table.new(:pair_first), User.arel_table)).select('1')
      unreviewed_pair_scope
        .where(selected_group.arel.exists)
        .select('pair_first.id AS id', 'pair_second.id AS second_user_id')
        .order(Arel.sql('pair_first.id, pair_second.id'))
    end

    def queue_pairs(rows)
      keys = rows.map { |row| [row.id, row.second_user_id] }
      users_by_id = load_users(keys.flatten)
      members_by_id = load_members(users_by_id)
      cases_by_pair = index_cases(cases_for_keys(keys))

      keys.filter_map do |ids|
        pair = build_current_pair(ids, users_by_id:, members_by_id:, cases: cases_by_pair.fetch(ids, []))
        pair if pair&.state == :unreviewed
      end
    end

    def legacy_flagged_users
      open_subject_ids = DuplicateReviewCase.open.where.not(subject_user_id: nil).select(:subject_user_id)
      open_candidate_ids = DuplicateReviewCaseCandidate.where(duplicate_review_case_id: DuplicateReviewCase.open.select(:id))
                                                       .where.not(candidate_user_id: nil).select(:candidate_user_id)
      unresolved_matches = current_pair_scope
                           .where(pair_cases.arel.exists.not.or(pair_cases(open_only: true).arel.exists))
                           .where('(pair_first.id = users.id OR pair_second.id = users.id)')
                           .select('1')

      User.where(needs_duplicate_review: true)
          .where.not(id: open_subject_ids)
          .where.not(id: open_candidate_ids)
          .where(unresolved_matches.arel.exists.not)
          .order(:last_name, :first_name, :id)
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

    private

    def current_pair_scope
      eligible_users = eligible_scope.select(:id, :first_name, :last_name, :date_of_birth)
      first = eligible_users.arel.as('pair_first')
      second = eligible_users.arel.as('pair_second')
      condition = first[:id].lt(second[:id]).and(same_match_key(first, second))
      join = Arel::Nodes::InnerJoin.new(second, Arel::Nodes::On.new(condition))
      User.unscoped.from(first).joins(join)
    end

    def unreviewed_pair_scope
      open_cases = DuplicateReviewCase.open.joins(:duplicate_review_case_candidates)
                                      .where(pair_case_sql).select('1')
      current_pair_scope.where(pair_cases.arel.exists.not)
                        .where(open_cases.arel.exists.not)
    end

    def same_match_key(first, second)
      first_name = Arel::Nodes::NamedFunction.new('LOWER', [first[:first_name]]).eq(
        Arel::Nodes::NamedFunction.new('LOWER', [second[:first_name]])
      )
      last_name = Arel::Nodes::NamedFunction.new('LOWER', [first[:last_name]]).eq(
        Arel::Nodes::NamedFunction.new('LOWER', [second[:last_name]])
      )
      first_name.and(last_name).and(first[:date_of_birth].eq(second[:date_of_birth]))
    end

    def pair_case_sql
      <<~SQL.squish
        ((duplicate_review_cases.subject_user_id = pair_first.id AND
         duplicate_review_case_candidates.candidate_user_id = pair_second.id) OR
        (duplicate_review_cases.subject_user_id = pair_second.id AND
         duplicate_review_case_candidates.candidate_user_id = pair_first.id))
      SQL
    end

    def pair_cases(open_only: false)
      scope = DuplicateReviewCase.reconciliation_pairs
      scope = scope.open if open_only
      scope.where(pair_case_sql).select('1')
    end

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
      index_cases(reconciliation_cases)
    end

    def index_cases(cases)
      cases.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |review_case, indexed|
        ids = [review_case.subject_user_id, review_case.duplicate_review_case_candidates.sole.candidate_user_id].sort
        indexed[ids] << review_case
      end
    end

    def cases_for_pair(ids)
      cases_for_keys([ids])
    end

    def cases_for_keys(keys)
      return [] if keys.empty?

      pair_conditions = keys.map do |first_id, second_id|
        DuplicateReviewCase.sanitize_sql_array(
          [
            '(duplicate_review_cases.subject_user_id = :first AND duplicate_review_case_candidates.candidate_user_id = :second) OR ' \
            '(duplicate_review_cases.subject_user_id = :second AND duplicate_review_case_candidates.candidate_user_id = :first)',
            { first: first_id, second: second_id }
          ]
        )
      end
      DuplicateReviewCase.reconciliation_pairs.where(pair_conditions.map { |condition| "(#{condition})" }.join(' OR '))
                         .includes(:duplicate_review_case_candidates).order(:id).to_a
    end

    def reconciliation_cases
      @reconciliation_cases ||=
        DuplicateReviewCase.reconciliation_pairs
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

    def load_members(users_by_id)
      summaries = load_application_summaries(users_by_id.keys)
      users_by_id.transform_values do |user|
        Member.from_user(user, application_summary: summaries.fetch(user.id, 'none'))
      end
    end

    def build_current_pair(ids, users_by_id:, members_by_id:, cases:)
      users = users_for(ids, users_by_id)
      return unless users&.all? { |user| eligible_user?(user) }

      state, review_case = current_state(cases)
      build_pair(users, members_by_id:, state:, review_case:)
    end

    def build_historical_pair(ids, users_by_id:, members_by_id:, cases:)
      users = users_for(ids, users_by_id)
      return unless users

      state, review_case = historical_state(users, cases)
      build_pair(users, members_by_id:, state:, review_case:)
    end

    def users_for(ids, users_by_id)
      users = ids.map { |id| users_by_id[id] }
      users if users.all?
    end

    def build_pair(users, members_by_id:, state:, review_case:)
      Pair.new(
        first: members_by_id.fetch(users.first.id),
        second: members_by_id.fetch(users.second.id),
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
