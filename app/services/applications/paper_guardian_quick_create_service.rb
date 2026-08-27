# frozen_string_literal: true

module Applications
  # Canonical writer for the paper form's JSON guardian quick-create boundary.
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
        selected = lock_selected_candidate
        if @selected_candidate_id.present? && selected.blank?
          outcome = failure('The selected guardian is no longer eligible.', result_data(:invalid_selection))
          raise ActiveRecord::Rollback
        end

        review_owner = identity_review_owner
        PaperIdentityCreationLock.lock!(review_owner.identity_facts)
        @review = review_owner.call

        if selected.present?
          unless review.selectable_candidates.any? { |candidate| candidate.id == selected.id }
            outcome = failure('The selected guardian was not among the current matches.', result_data(:invalid_selection))
            raise ActiveRecord::Rollback
          end

          outcome = success(nil, result_data(:selected, user: selected, created: false))
          raise ActiveRecord::Rollback
        end

        unless review.permits_creation?
          outcome = failure(review_error_message, result_data(review.state))
          raise ActiveRecord::Rollback
        end

        contact_flags = PaperContactFlags.new(@request_params, scope: :guardian)
        creation = UserCreationService.new(
          contact_flags.apply_to(@attrs),
          is_managing_adult: true,
          skip_user_lookup: true,
          skip_email_validation: contact_flags.skip_email_validation?,
          skip_phone_validation: contact_flags.skip_phone_validation?
        ).call
        unless creation.success?
          outcome = failure(creation.message, result_data(:invalid, errors: creation.data&.dig(:errors)))
          raise ActiveRecord::Rollback
        end

        user = creation.data.fetch(:user)
        record_confirmation(user) if review.confirmed?
        outcome = success(nil, result_data(:created, user: user, created: true))
      end

      outcome
    rescue ActiveRecord::RecordNotUnique
      # Different name/DOB facts take different advisory locks, so concurrent quick-creates can
      # still race on the unique contact indexes. The failed transaction wrote nothing. Re-run the
      # canonical review after rollback so the newly committed contact owner becomes a hard block
      # instead of a 500 that invites staff to retry the same person.
      @review = identity_review_owner(submitted_token: nil).call
      failure(record_not_unique_message, result_data(review.blocked? ? :blocked : :error))
    end

    private

    def lock_selected_candidate
      return if @selected_candidate_id.blank?

      candidate = User.lock.find_by(id: @selected_candidate_id)
      candidate if candidate&.paper_guardian_candidate?
    end

    def identity_review_owner(submitted_token: @submitted_token)
      PaperIdentityReview.new(
        constituent_params: @attrs,
        contact_flag_params: @request_params,
        admin: @admin,
        submitted_token: submitted_token,
        context: :guardian
      )
    end

    def record_not_unique_message
      return review_error_message if review.blocked?

      'Guardian contact information changed while saving. Search for the guardian before trying again.'
    end

    def review_error_message
      case review.state
      when :error then 'Identity review is temporarily unavailable. Try again.'
      when :blocked then 'A guardian with this email or phone already exists. Select that guardian or correct the contact information.'
      when :needs_confirmation then 'Review the possible matches before creating a new guardian.'
      when :invalid_decision then 'The guardian details or review changed. Save Guardian to review again.'
      else 'Guardian identity review was refused.'
      end
    end

    def result_data(state, extra = {})
      { state: state, review: review }.merge(extra)
    end

    def record_confirmation(user)
      AuditEventService.log(
        action: 'paper_identity_no_match_confirmed',
        actor: @admin,
        auditable: user,
        metadata: {
          decision_context: 'guardian_quick_create',
          role: 'guardian',
          candidate_ids: review.candidate_ids,
          candidate_count: review.candidate_ids.size,
          reason_codes: review.reasons
        }
      )
    end
  end
end
