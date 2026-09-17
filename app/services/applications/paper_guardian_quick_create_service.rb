# frozen_string_literal: true

module Applications
  # Saves or explicitly selects a guardian through the paper review and case owners.
  class PaperGuardianQuickCreateService < BaseService
    attr_reader :review

    def initialize(attrs:, request_params:, admin:, submitted_token: nil, selected_candidate_id: nil)
      super()
      @attrs = attrs
      @request_params = request_params
      @admin = admin
      @submitted_token = submitted_token
      @selected_candidate_id = selected_candidate_id
    end

    def call
      outcome = nil
      ActiveRecord::Base.transaction do
        owner = identity_review_owner
        PaperIdentityCreationLock.lock!(owner.identity_facts)
        @review = owner.call(lock: true)
        unless review.selected? || review.permits_creation?
          outcome = failure(review_error_message, result_data(review.state))
          raise ActiveRecord::Rollback
        end

        if !review.clear? && @request_params[:identity_rationale].blank?
          outcome = failure('Explain the identity decision before continuing.', result_data(:invalid))
          raise ActiveRecord::Rollback
        end

        user = review.selected_user
        unless user
          flags = PaperContactFlags.new(@request_params, scope: :guardian)
          creation = UserCreationService.new(
            flags.apply_to(@attrs), is_managing_adult: true, skip_user_lookup: true,
                                    skip_email_validation: flags.skip_email_validation?, skip_phone_validation: flags.skip_phone_validation?
          ).call
          unless creation.success?
            outcome = failure(creation.message, result_data(:invalid, errors: creation.data&.dig(:errors)))
            raise ActiveRecord::Rollback
          end
          user = creation.data.fetch(:user)
        end

        DuplicateReviewCases::CreateService.record_paper_decision!(
          review: review, user: user, actor: @admin, rationale: @request_params[:identity_rationale],
          receipt: @submitted_token
        )
        outcome = success(nil, result_data(review.selected? ? :selected : :created, user: user, created: !review.selected?))
      end
      outcome
    rescue ActiveRecord::RecordNotUnique
      @review = identity_review_owner(submitted_token: nil).call
      failure('Guardian contact information changed while saving. Review the current matches.', result_data(review.state))
    rescue DuplicateReviewCases::CreateService::IneligibleParticipantError => e
      failure(e.message, result_data(:invalid))
    end

    private

    def identity_review_owner(submitted_token: @submitted_token)
      PaperIdentityReview.new(
        constituent_params: @attrs, contact_flag_params: @request_params, admin: @admin,
        submitted_token: submitted_token, context: :guardian, selected_candidate_id: @selected_candidate_id,
        determination: @request_params[:identity_determination]
      )
    end

    def review_error_message
      case review.state
      when :error then 'Identity review is temporarily unavailable. Try again.'
      when :blocked then 'A guardian with this email or phone already exists. Select that guardian or correct the contact information.'
      when :needs_confirmation then 'Review the possible matches before creating a new guardian.'
      else 'The guardian details or review changed. Review again.'
      end
    end

    def result_data(state, extra = {})
      { state: state, review: review }.merge(extra)
    end
  end
end
