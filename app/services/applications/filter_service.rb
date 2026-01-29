# frozen_string_literal: true

module Applications
  class FilterService < BaseService
    attr_reader :scope, :params

    def initialize(scope, params = {})
      super()
      @scope = scope
      @params = params
    end

    # Apply filters based on the provided parameters
    def apply_filters
      filtered_scope = build_filtered_scope
      success(nil, filtered_scope)
    rescue StandardError => e
      handle_filter_error(e)
    end

    private

    def build_filtered_scope
      scope
        .then { |result| apply_conditional_status_filter(result) }
        .then { |result| apply_conditional_explicit_status_filter(result) }
        .then { |result| apply_conditional_date_range_filter(result) }
        .then { |result| apply_conditional_search_filter(result) }
        .then { |result| apply_guardian_dependent_text_searches(result) }
        .then { |result| apply_guardian_relationship_filters(result) }
    end

    def apply_conditional_status_filter(result)
      params[:filter].present? ? apply_status_filter(result, params[:filter]) : result
    end

    def apply_conditional_explicit_status_filter(result)
      params[:status].present? ? result.where(status: params[:status]) : result
    end

    def apply_conditional_date_range_filter(result)
      params[:date_range].present? ? apply_date_range_filter(result) : result
    end

    def apply_conditional_search_filter(result)
      params[:q].present? ? apply_search_filter(result) : result
    end

    def handle_filter_error(error)
      Rails.logger.error "Error applying filters: #{error.message}"
      Rails.logger.error error.backtrace.join("\n")
      # Return the original scope in the data field on failure, along with an error message.
      # Use positional parameters to match the BaseService method definition
      failure("Error applying filters: #{error.message}", scope)
    end

    def apply_status_filter(scope, filter)
      case filter
      when 'active'
        scope.active
      when 'draft'
        scope.where(status: :draft)
      when 'in_progress'
        scope.where(status: :in_progress)
      when 'approved'
        scope.where(status: :approved)
      when 'rejected'
        scope.where(status: :rejected)
      when 'proofs_needing_review'
        # Use Rails enum mapping to get the correct integer values
        scope.where(income_proof_status: :not_reviewed).or(scope.where(residency_proof_status: :not_reviewed))
      when 'awaiting_medical_response'
        scope.where(status: :awaiting_dcf)
      when 'medical_certs_to_review'
        # Only include applications that are in progress and have received certs
        scope.where(status: :in_progress, medical_certification_status: :received)
      when 'training_requests'
        # Match the controller logic: check notifications first, then fall back to training sessions
        notification_app_ids = Notification.where(action: 'training_requested')
                                           .where(notifiable_type: 'Application')
                                           .select(:notifiable_id)
                                           .distinct
                                           .pluck(:notifiable_id)

        if notification_app_ids.any?
          scope.where(id: notification_app_ids)
        else
          # Fall back to training sessions if no notifications
          scope.with_pending_training
        end
      when 'dependent_applications'
        # Filter applications that are for dependents (have a managing_guardian)
        scope.where.not(managing_guardian_id: nil)
      when 'digitally_signed_needs_review'
        # Applications that have been digitally signed and need admin review
        scope.digitally_signed_needs_review
      else
        scope
      end
    end

    def apply_date_range_filter(scope)
      case params[:date_range]
      when 'current_fy'
        fy = fiscal_year
        date_range = Date.new(fy, 7, 1)..Date.new(fy + 1, 6, 30)
        scope.where(created_at: date_range)
      when 'previous_fy'
        fy = fiscal_year - 1
        date_range = Date.new(fy, 7, 1)..Date.new(fy + 1, 6, 30)
        scope.where(created_at: date_range)
      when 'last_30'
        scope.where(created_at: 30.days.ago.beginning_of_day..)
      when 'last_90'
        scope.where(created_at: 90.days.ago.beginning_of_day..)
      else
        scope
      end
    end

    def apply_search_filter(scope)
      search_term = "%#{params[:q]}%"
      # Join with users table to search on user fields in a single query
      scope.joins(:user).where(
        'applications.id::text ILIKE ? OR users.first_name ILIKE ? OR users.last_name ILIKE ? OR users.email ILIKE ?',
        search_term, search_term, search_term, search_term
      )
    end

    # Support text queries for guardian and dependent specific searches
    def apply_guardian_dependent_text_searches(scope)
      result = scope

      if params[:managing_guardian_q].present?
        q = "%#{params[:managing_guardian_q]}%"
        # Explicit join to users as managing guardians
        result = result.joins('INNER JOIN users mg_users ON mg_users.id = applications.managing_guardian_id')
                       .where('mg_users.first_name ILIKE ? OR mg_users.last_name ILIKE ? OR mg_users.email ILIKE ?', q, q, q)
      end

      if params[:dependent_q].present?
        q = "%#{params[:dependent_q]}%"
        result = result.joins(:user)
                       .where('users.first_name ILIKE ? OR users.last_name ILIKE ? OR users.email ILIKE ?', q, q, q)
      end

      result
    end

    def apply_guardian_relationship_filters(scope)
      scope
        .then { |result| apply_managing_guardian_filter(result) }
        .then { |result| apply_guardian_dependents_filter(result) }
        .then { |result| apply_specific_dependent_filter(result) }
        .then { |result| apply_only_dependents_filter(result) }
        .then { |result| result || Application.none }
    end

    def apply_managing_guardian_filter(scope)
      return scope if params[:managing_guardian_id].blank?

      scope.where(managing_guardian_id: params[:managing_guardian_id])
    end

    def apply_guardian_dependents_filter(scope)
      return scope if params[:guardian_id].blank?

      guardian = User.find_by(id: params[:guardian_id])
      return scope if guardian.blank?

      scope.for_dependents_of(guardian)
    end

    def apply_specific_dependent_filter(scope)
      return scope if params[:dependent_id].blank?

      scope.where(user_id: params[:dependent_id])
    end

    def apply_only_dependents_filter(scope)
      # Support both legacy only_dependent_apps=true and new for_minors checkbox
      return scope unless params[:only_dependent_apps] == 'true' || params[:for_minors].present?

      scope.where.not(managing_guardian_id: nil)
    end

    def fiscal_year
      current_date = Date.current
      current_date.month >= 7 ? current_date.year : current_date.year - 1
    end
  end
end
