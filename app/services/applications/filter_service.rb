# frozen_string_literal: true

module Applications
  class FilterService < BaseService
    SORT_COLUMNS = {
      'created_at' => 'created_at', 'application_date' => 'created_at',
      'applicant' => 'applicant', 'user.last_name' => 'applicant',
      'status' => 'status', 'next_action' => 'next_action'
    }.freeze
    SORT_DIRECTIONS = { 'created_at' => 'desc', 'applicant' => 'asc', 'status' => 'desc', 'next_action' => 'asc' }.freeze
    NEXT_ACTION_LABELS = {
      review_proof: 'Review proof', review_certification: 'Review certification',
      review_application: 'Review application', open_application: 'Open application'
    }.freeze

    class << self
      def sort_column(params = {})
        SORT_COLUMNS.fetch(params[:sort].to_s, 'created_at')
      end

      def sort_direction(params = {})
        requested = params[:direction].to_s
        requested.in?(%w[asc desc]) ? requested : SORT_DIRECTIONS.fetch(sort_column(params))
      end

      # The list and its sort use the same projected values. The derived table also keeps COUNT(*) valid.
      def with_list_details(scope, params = {})
        projection = scope.except(:order, :includes, :preload, :eager_load)
                          .reselect(Application.arel_table[Arel.star], status_entry_expression.as('current_status_entered_at'), next_action_expression.as('next_action'))
        result = Application.unscoped.from(projection, :applications)
        result = result.includes(*scope.includes_values) if scope.includes_values.any?
        result = result.preload(*scope.preload_values) if scope.preload_values.any?
        result = result.eager_load(*scope.eager_load_values) if scope.eager_load_values.any?
        apply_sort(result, params)
      end

      private

      def apply_sort(result, params)
        direction = sort_direction(params)
        applications = Application.arel_table
        order = case sort_column(params)
                when 'applicant'
                  result = result.left_joins(:user)
                  [order_expression(User.arel_table[:last_name].lower, direction).nulls_last,
                   order_expression(User.arel_table[:first_name].lower, direction).nulls_last]
                when 'status'
                  timestamp_direction = direction == 'desc' ? 'asc' : 'desc'
                  [order_expression(applications[:current_status_entered_at], timestamp_direction).nulls_last]
                when 'next_action'
                  [order_expression(applications[:next_action], direction)]
                else
                  [order_expression(applications[:created_at], direction)]
                end
        result.reorder(*order, order_expression(applications[:id], direction))
      end

      def order_expression(expression, direction)
        direction == 'asc' ? expression.asc : expression.desc
      end

      def status_entry_expression
        applications = Application.arel_table
        changes = ApplicationStatusChange.arel_table
        lifecycle = ApplicationStatusChange.lifecycle.where(changes[:application_id].eq(applications[:id]))
        current_status = Application.statuses.reduce(Arel::Nodes::Case.new(applications[:status])) do |expression, (name, value)|
          expression.when(value).then(name)
        end
        latest = lifecycle.where(changes[:to_status].eq(current_status))
                          .order(changed_at: :desc, id: :desc).limit(1).select(:changed_at)
        initial_paper_statuses = applications[:status].in(Application.statuses.values_at('in_progress', 'awaiting_proof'))
        paper_initial_state = applications[:submission_method].eq(Application.submission_methods.fetch('paper')).and(initial_paper_statuses)
        known_initial_status = applications[:status].eq(Application.statuses.fetch('draft')).or(paper_initial_state)
        initial_date = Arel::Nodes::Case.new.when(lifecycle.arel.exists.not.and(known_initial_status)).then(applications[:created_at])
        Arel::Nodes::NamedFunction.new('COALESCE', [latest.arel, initial_date])
      end

      def next_action_expression
        certification_files = ActiveStorage::Attachment.where(record_type: 'Application', name: 'disability_certification').select(:record_id)
        certification_review = Application.active.where(disability_certification_status: %i[requested received], id: certification_files)
        application_review = Application.active.where(disability_certification_status: :approved, residency_proof_status: :approved, id_proof_status: :approved)
                                        .where('income_proof_required = FALSE OR income_proof_status = ?', Application.income_proof_statuses.fetch('approved'))
        actions = {
          review_proof: Application.awaiting_proof_review,
          review_certification: certification_review,
          review_application: application_review
        }
        expression = actions.reduce(Arel::Nodes::Case.new) do |clause, (action, relation)|
          clause.when(Application.arel_table[:id].in(relation.select(:id).arel)).then(NEXT_ACTION_LABELS.fetch(action))
        end
        expression.else(NEXT_ACTION_LABELS.fetch(:open_application))
      end
    end

    attr_reader :scope, :params

    def initialize(scope, params = {})
      super()
      @scope = scope
      @params = params
    end

    def apply_filters
      filtered_scope = self.class.with_list_details(build_filtered_scope, params)
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
      return result if params[:status].blank?

      # 'active' names a scope, not an enum value.
      # It selects in_progress, awaiting_proof, reminder_sent, and awaiting_dcf.
      return apply_status_filter(result, 'active') if params[:status] == 'active'

      result.where(status: params[:status])
    end

    def apply_conditional_date_range_filter(result)
      params[:date_range].present? ? apply_date_range_filter(result) : result
    end

    def apply_conditional_search_filter(result)
      params[:q].present? ? apply_search_filter(result) : result
    end

    def handle_filter_error(error)
      Rails.logger.error "Error applying filters: #{error.class.name}"
      # A failure retains the original scope in Result#data.
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
        scope.with_proofs_needing_review
      when 'awaiting_disability_certification'
        scope.where(status: :awaiting_dcf)
      when 'disability_certs_to_review'
        scope.where(status: :in_progress, disability_certification_status: :received)
      when 'pending_provider_info'
        scope.pending_provider_info
      when 'training_requests'
        # training_requested_at drives this queue independently of notification delivery.
        scope.with_pending_training_request
      when 'evaluation_requests'
        # Only explicit evaluation requests enter this queue. Equipment approval alone does not create a request.
        scope.with_pending_evaluation_request
      when 'evaluations_needing_reassignment'
        scope.needing_evaluator_reassignment
      when 'training_needing_reassignment'
        scope.needing_trainer_reassignment
      when 'dependent_applications'
        scope.where.not(managing_guardian_id: nil)
      when 'digitally_signed_needs_review'
        scope.digitally_signed_needs_review
      else
        scope
      end
    end

    def apply_date_range_filter(scope)
      case params[:date_range]
      when 'current_fy'
        fy = fiscal_year
        date_range = FiscalYear.time_range(FiscalYear.start_date_for(fy), FiscalYear.end_date_for(fy))
        scope.where(created_at: date_range)
      when 'previous_fy'
        fy = fiscal_year - 1
        date_range = FiscalYear.time_range(FiscalYear.start_date_for(fy), FiscalYear.end_date_for(fy))
        scope.where(created_at: date_range)
      when 'last_30', 'last_60', 'last_90', 'last_120'
        days = params[:date_range].delete_prefix('last_').to_i
        scope.where(created_at: days.days.ago.beginning_of_day..)
      when 'last_12_months'
        scope.where(created_at: 12.months.ago.beginning_of_day..)
      else
        scope
      end
    end

    def apply_search_filter(scope)
      search_term = search_pattern(params[:q])
      result = scope.joins(:user)
      result.where('applications.id::text ILIKE :q OR users.first_name ILIKE :q OR users.last_name ILIKE :q',
                   q: search_term)
            .or(result.where(user_id: email_search_user_ids(params[:q])))
    end

    def apply_guardian_dependent_text_searches(scope)
      result = scope

      if params[:managing_guardian_q].present?
        q = search_pattern(params[:managing_guardian_q])
        result = result.joins('INNER JOIN users mg_users ON mg_users.id = applications.managing_guardian_id')
        result = result.where('mg_users.first_name ILIKE :q OR mg_users.last_name ILIKE :q', q: q)
                       .or(result.where(managing_guardian_id: email_search_user_ids(params[:managing_guardian_q])))
      end

      if params[:dependent_q].present?
        q = search_pattern(params[:dependent_q])
        result = result.joins(:user)
        result = result.where('users.first_name ILIKE :q OR users.last_name ILIKE :q', q: q)
                       .or(result.where(user_id: email_search_user_ids(params[:dependent_q])))
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
      # Both parameter names select applications managed by a guardian, regardless of applicant age.
      return scope unless params[:only_dependent_apps] == 'true' || params[:for_minors].present?

      scope.where.not(managing_guardian_id: nil)
    end

    def fiscal_year
      FiscalYear.current_start_year
    end

    def email_search_user_ids(query)
      User.with_email_search_match(query).select(:id)
    end

    def search_pattern(query)
      "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
    end
  end
end
