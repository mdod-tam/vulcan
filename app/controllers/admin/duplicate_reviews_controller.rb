# frozen_string_literal: true

module Admin
  # Admin workflow for resolving flagged duplicate records: review queue, case detail, the audited
  # non-merge resolution that records the two records as different people, and same-person merge.
  # All data mutation happens in the service layer; this controller only translates the form.
  class DuplicateReviewsController < BaseController
    before_action :set_review_case, only: %i[show resolve merge]

    def index
      @open_cases = DuplicateReviewCase.open_cases
                                       .includes(:subject_user, duplicate_review_case_candidates: :candidate_user)
                                       .order(opened_at: :desc)
      @legacy_flagged_users = legacy_flagged_users
    end

    def show
      @subject = @review_case.subject_user
      @candidates = @review_case.duplicate_review_case_candidates.includes(:candidate_user).to_a
      @candidate_users = @candidates.filter_map(&:candidate_user)
    end

    def resolve
      return if reject_stale_resolution_form?

      result = DuplicateReviewCases::ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: current_user,
        # Neither the determination nor the action is passed: the service owns both. The only
        # handling of a submitted value is the rollover guard above, which rejects conflicts
        # rather than storing them.
        rationale: params[:rationale],
        reason_codes: Array(params[:reason_codes])
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
        reason_codes: Array(params[:reason_codes]),
        contact_choices: merge_contact_choices(canonical:, duplicate:),
        delivery_choice: source_for_pair_user_id(params[:delivery_user_id], canonical:, duplicate:)
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

    private

    # Rollover guard for the resolve form. `ResolutionService` accepts neither a determination nor
    # an action -- the server owns both -- so these two parameters are read only to decide whether
    # the submitting page is stale. Absent, or carrying the value the server would choose anyway,
    # proceeds; any conflicting value is rejected without mutation.
    #
    # Rejecting rather than ignoring is the point. A cached or long-open page can still offer
    # outcomes the server no longer accepts, and treating those as inert would hand the admin a
    # keep-separate resolution when they asked for something else -- the opposite of their stated
    # intent, on a decision that releases a submission gate. The guard is inert once every rendered
    # form is current.
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

    def legacy_flagged_users
      subject_ids = DuplicateReviewCase.open_cases.where.not(subject_user_id: nil).pluck(:subject_user_id)
      User.where(needs_duplicate_review: true)
          .where.not(id: subject_ids)
          .order(:last_name, :first_name)
    end

    # Only the case subject and its recorded candidates are mergeable, so a forged id
    # cannot pull an unrelated user into a merge. The merge form scopes each comparison to
    # a two-record pair and the admin picks which record survives as canonical.
    def merge_pair
      allowed = allowed_pair_ids
      pair_ids = Array(params[:pair_ids]).map(&:to_i).uniq
      canonical_id = params[:canonical_user_id].to_i
      return [nil, nil] unless pair_ids.size == 2
      return [nil, nil] unless (pair_ids - allowed).empty?
      return [nil, nil] unless pair_ids.include?(canonical_id)
      # The UI only ever renders subject <-> candidate comparisons, so a valid merge must
      # include the case subject. This blocks a forged candidate <-> candidate pairing.
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
        # Login identity is never a transferable contact choice. The selected canonical
        # always keeps its own email/password/MFA authority.
        email: 'canonical',
        phone: source_for_pair_user_id(params.dig(:contact, :phone_user_id), canonical:, duplicate:),
        phone_type: params.dig(:contact, :phone_type),
        address: source_for_pair_user_id(params.dig(:contact, :address_user_id), canonical:, duplicate:)
      }
    end

    def source_for_pair_user_id(value, canonical:, duplicate:)
      selected_id = value.to_i
      return 'canonical' if selected_id == canonical.id
      return 'duplicate' if selected_id == duplicate.id

      nil
    end
  end
end
