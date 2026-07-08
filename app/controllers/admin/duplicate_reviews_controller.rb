# frozen_string_literal: true

module Admin
  # Admin workflow for resolving flagged duplicate records: review queue, case detail,
  # audited approve/ignore/keep-separate resolutions, and same-person merge. All data
  # mutation happens in the service layer; this controller only translates the form.
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
      result = DuplicateReviewCases::ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: current_user,
        action: params[:resolution_action],
        determination: params[:determination],
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
        contact_choices: merge_contact_choices,
        delivery_choice: params[:delivery_choice]
      ).call

      if result.success?
        redirect_to admin_user_path(canonical), notice: 'Duplicate record merged into the canonical account.'
      else
        redirect_to admin_duplicate_review_path(@review_case), alert: result.message
      end
    end

    def clear_flag
      user = User.find(params[:user_id])
      rationale = params[:rationale].to_s.strip
      return redirect_to admin_duplicate_reviews_path, alert: 'A rationale is required to clear a review flag.' if rationale.blank?

      # Keep flag and cases in sync: an open case owns the flag, so it must be resolved
      # through the case (approve/ignore/keep-separate/merge), not cleared out from under it.
      if DuplicateReviewCase.open_cases.for_subject(user).exists?
        return redirect_to admin_duplicate_reviews_path,
                           alert: 'This record has an open review case; resolve the case instead of clearing the flag.'
      end

      user.update!(needs_duplicate_review: false)
      AuditEventService.log(
        action: 'duplicate_review_flag_cleared',
        actor: current_user,
        auditable: user,
        metadata: { user_id: user.id, rationale: rationale }
      )
      redirect_to admin_duplicate_reviews_path, notice: 'Review flag cleared.'
    end

    private

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

    def merge_contact_choices
      {
        email: params.dig(:contact, :email),
        phone: params.dig(:contact, :phone),
        phone_type: params.dig(:contact, :phone_type),
        address: params.dig(:contact, :address)
      }
    end
  end
end
