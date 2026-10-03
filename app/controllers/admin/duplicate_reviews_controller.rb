# frozen_string_literal: true

module Admin
  # Admin duplicate review: queue, case detail, keep-separate resolution, and same-person merge.
  # Services do all data changes. This controller only translates form parameters.
  class DuplicateReviewsController < BaseController
    before_action :set_review_case, only: %i[show resolve merge]

    def index
      @open_cases = DuplicateReviewCase.open_cases
                                       .includes(:subject_user, duplicate_review_case_candidates: :candidate_user)
                                       .order(opened_at: :desc)
      population_pairs = DuplicateReconciliation::Population.new.pairs
      open_pair_keys = @open_cases.flat_map do |review_case|
        review_case.duplicate_review_case_candidates.filter_map do |candidate|
          next if review_case.subject_user_id.blank? || candidate.candidate_user_id.blank?

          [review_case.subject_user_id, candidate.candidate_user_id].sort
        end
      end
      @unreviewed_pairs = population_pairs.select do |pair|
        pair.state == :unreviewed && open_pair_keys.exclude?(pair.ids)
      end
      @unreviewed_match_groups = DuplicateReconciliation::PairGroup.build_all(@unreviewed_pairs)
      unresolved_pair_ids = population_pairs.select(&:unresolved?).flat_map(&:ids).uniq
      @legacy_flagged_users = legacy_flagged_users(excluding_pair_ids: unresolved_pair_ids)
    end

    def show
      @subject = @review_case.subject_user
      @candidates = @review_case.duplicate_review_case_candidates.includes(:candidate_user).to_a
      candidate_users = @candidates.filter_map(&:candidate_user).reject(&:merged?)
      record_users = [@subject, *candidate_users].compact.uniq
      ActiveRecord::Associations::Preloader.new(
        records: record_users,
        associations: %i[applications guardian_relationships_as_guardian guardian_relationships_as_dependent]
      ).call
      related_user_ids = record_users.flat_map do |user|
        user.guardian_relationships_as_guardian.map(&:dependent_id) +
          user.guardian_relationships_as_dependent.map(&:guardian_id)
      end.uniq
      @relationship_users_by_id = User.where(id: related_user_ids).preload(:applications).index_by(&:id)
    end

    def resolve
      return if reject_stale_resolution_form?

      result = DuplicateReviewCases::ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: current_user,
        # The service owns the determination and the action. Submitted values only feed the
        # stale-form guard above.
        rationale: params[:rationale],
        reason_codes: ['admin_reviewed']
      ).call

      if result.success?
        redirect_to admin_duplicate_reviews_path, notice: 'Duplicate review case resolved.'
      else
        redirect_to admin_duplicate_review_path(@review_case), alert: result.message
      end
    end

    def merge
      canonical, duplicate = merge_pair
      if canonical.nil? || duplicate.nil? || canonical == duplicate
        return redirect_to admin_duplicate_review_path(@review_case),
                           alert: 'Select which record is canonical and which is the duplicate.'
      end

      result = Users::DuplicateMergeService.new(
        actor: current_user,
        duplicate_review_case: @review_case,
        canonical_user: canonical,
        duplicate_user: duplicate,
        same_person_confirmed: params[:same_person_confirmed],
        rationale: params[:rationale],
        reason_codes: merge_reason_codes,
        contact_choices: merge_contact_choices(canonical:, duplicate:),
        delivery_choice: merge_delivery_choice(canonical:, duplicate:)
      ).call

      if result.success?
        redirect_to admin_user_path(canonical), notice: 'Duplicate record merged into the canonical account.'
      else
        redirect_to admin_duplicate_review_path(@review_case), alert: result.message
      end
    end

    def clear_flag
      user = User.find(params[:user_id])
      result = DuplicateReviewCases::ClearFlagService.new(user: user, actor: current_user, rationale: params[:rationale]).call

      if result.success?
        redirect_to admin_duplicate_reviews_path, notice: result.message
      else
        redirect_to admin_duplicate_reviews_path, alert: result.message
      end
    end

    def review_pair
      result = DuplicateReconciliation::ReviewPairService.new(
        actor: current_user,
        first_user_id: params[:first_user_id],
        second_user_id: params[:second_user_id]
      ).call

      if result.success?
        redirect_to admin_duplicate_review_path(result.data.fetch(:duplicate_review_case)), notice: result.message
      else
        redirect_to admin_duplicate_reviews_path, alert: result.message
      end
    end

    private

    # Stale-form guard. These parameters only tell if the page is stale. An absent value or the
    # server's own value continues. Any other value is rejected with no change.
    # Do not ignore a conflict. An old page can offer outcomes the server no longer accepts.
    # Ignoring them would apply keep-separate against the admin's choice and release a submission gate.
    def reject_stale_resolution_form?
      determination = params[:determination]
      action = params[:resolution_action]

      stale = (determination.present? && determination != DuplicateReviewCases::ResolutionService::NON_MERGE_DETERMINATION) ||
              (action.present? && action != 'keep_separate')
      return false unless stale

      redirect_to admin_duplicate_review_path(@review_case),
                  alert: 'This form was out of date, so we reloaded the case. Review the current options and resolve it again.'
      true
    end

    def set_review_case
      @review_case = DuplicateReviewCase.find(params[:id])
    end

    def legacy_flagged_users(excluding_pair_ids:)
      open_case_participant_ids = @open_cases.flat_map do |review_case|
        [review_case.subject_user_id, *review_case.duplicate_review_case_candidates.map(&:candidate_user_id)]
      end.compact.uniq
      User.where(needs_duplicate_review: true)
          .where.not(id: open_case_participant_ids + excluding_pair_ids)
          .order(:last_name, :first_name)
    end

    # Only the case subject and its recorded candidates can merge, so a forged id cannot add
    # an unrelated user. The form sends one two-record pair and the admin's canonical choice.
    def merge_pair
      allowed = allowed_pair_ids
      pair_ids = Array(params[:pair_ids]).map(&:to_i).uniq
      canonical_id = params[:canonical_user_id].to_i
      return [nil, nil] unless pair_ids.size == 2
      return [nil, nil] unless (pair_ids - allowed).empty?
      return [nil, nil] unless pair_ids.include?(canonical_id)
      # The UI shows only subject-to-candidate pairs. This blocks a forged candidate-to-candidate pair.
      return [nil, nil] unless pair_ids.include?(@review_case.subject_user_id)

      duplicate_id = (pair_ids - [canonical_id]).first
      [User.find_by(id: canonical_id), User.find_by(id: duplicate_id)]
    end

    def allowed_pair_ids
      ids = [@review_case.subject_user_id]
      ids += @review_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
      ids.compact.uniq
    end

    def merge_contact_choices(canonical:, duplicate:)
      {
        # Login identity never transfers. The canonical user keeps its email, password, and MFA.
        email: 'canonical',
        phone: merge_contact_source(:phone, canonical:, duplicate:),
        phone_type: merge_phone_type_choice,
        address: merge_contact_source(:address, canonical:, duplicate:)
      }
    end

    # Agreement markers come from collapsed read-only rows but are untrusted. DuplicateMergeService
    # locks both users and refuses the merge unless the current values are still equal.
    def merge_contact_source(field, canonical:, duplicate:)
      return Users::DuplicateMergeService::AGREED_SOURCE if params.dig(:contact, :"#{field}_agreed") == '1'

      source_for_pair_user_id(params.dig(:contact, :"#{field}_user_id"), canonical:, duplicate:)
    end

    def merge_phone_type_choice
      return Users::DuplicateMergeService::AGREED_SOURCE if params.dig(:contact, :phone_type_agreed) == '1'

      params.dig(:contact, :phone_type)
    end

    def merge_delivery_choice(canonical:, duplicate:)
      return Users::DuplicateMergeService::AGREED_SOURCE if params[:delivery_agreed] == '1'

      source_for_pair_user_id(params[:delivery_user_id], canonical:, duplicate:)
    end

    # Reason codes come from the case, not the form, so a forged request cannot rewrite merge
    # audit metadata. The admin records the same-person judgment in the required rationale.
    def merge_reason_codes
      reason_codes = Array(@review_case.metadata['reason_codes']).map(&:to_s).compact_blank.uniq
      return reason_codes if reason_codes.any?

      ['admin_reviewed']
    end

    def source_for_pair_user_id(value, canonical:, duplicate:)
      selected_id = value.to_i
      return 'canonical' if selected_id == canonical.id
      return 'duplicate' if selected_id == duplicate.id

      nil
    end
  end
end
