# frozen_string_literal: true

module Users
  # Service for filtering users in the admin interface
  # Follows the same pattern as Applications::FilterService
  # Key capabilities:
  # - Text search (q): Searches first_name, last_name, email with multi-term support
  # - Role filter: Filter by user type (administrator, evaluator, constituent, vendor, trainer)
  # - Needs review filter: Filter users flagged for duplicate review
  # - Relationship filter: Filter by guardian/dependent status
  # - Sorting: Configurable column sorting with safe column validation
  #
  # Usage:
  #   result = Users::FilterService.new(User.all, params).apply_filters
  #   if result.success?
  #     @users = result.data
  #   end
  class FilterService < BaseService
    attr_reader :scope, :params

    # Role type mapping - matches Admin::UsersController::VALID_USER_TYPES
    ROLE_TYPE_MAPPING = {
      'administrator' => 'Users::Administrator',
      'admin' => 'Users::Administrator',
      'evaluator' => 'Users::Evaluator',
      'constituent' => 'Users::Constituent',
      'vendor' => 'Users::Vendor',
      'trainer' => 'Users::Trainer'
    }.freeze

    SORTABLE_COLUMNS = %w[type last_name first_name email created_at].freeze

    def initialize(scope, params = {})
      super()
      @scope = scope
      @params = params
    end

    # Apply filters based on the provided parameters
    # @return [BaseService::Result] with filtered scope in data
    def apply_filters
      filtered_scope = build_filtered_scope
      success(nil, filtered_scope)
    rescue StandardError => e
      handle_filter_error(e)
    end

    private

    def build_filtered_scope
      scope
        .then { |result| apply_search_filter(result) }
        .then { |result| apply_role_filter(result) }
        .then { |result| apply_needs_review_filter(result) }
        .then { |result| apply_relationship_filter(result) }
        .then { |result| apply_sorting(result) }
    end

    # Text search across first_name, last_name, email
    # Consolidates logic from Admin::UsersController#apply_search_filter and build_search_query
    def apply_search_filter(result)
      return result if params[:q].blank?

      search_term = params[:q].to_s.strip
      return result if search_term.empty?

      # Handle multi-term search (e.g., "John Doe")
      search_terms = search_term.split(/\s+/)

      if search_terms.length == 1
        apply_single_term_search(result, search_terms.first)
      else
        apply_multi_term_search(result, search_term, search_terms)
      end
    end

    def apply_single_term_search(result, term)
      query_term = "%#{term.downcase}%"
      result.where(
        'LOWER(first_name) ILIKE :q OR LOWER(last_name) ILIKE :q OR LOWER(email) ILIKE :q',
        q: query_term
      )
    end

    # Multi-term search: first try full name match, then fall back to OR matching
    # Matches the logic in Admin::UsersController#build_search_query
    def apply_multi_term_search(result, full_term, terms)
      # First try full name match using CONCAT
      full_name_term = "%#{full_term.downcase}%"
      full_name_result = result.where(
        "LOWER(CONCAT(first_name, ' ', last_name)) ILIKE :q OR LOWER(email) ILIKE :q",
        q: full_name_term
      )

      # If we get results, use them; otherwise fall back to OR matching individual terms
      return full_name_result if full_name_result.exists?

      # Build OR condition using Arel for safety (matches build_multi_term_condition)
      table = User.arel_table
      condition = terms.inject(nil) do |cond, term|
        term_pattern = "%#{term.downcase}%"
        term_cond = table[:first_name].lower.matches(term_pattern)
                                      .or(table[:last_name].lower.matches(term_pattern))
                                      .or(table[:email].lower.matches(term_pattern))
        cond ? cond.or(term_cond) : term_cond
      end

      result.where(condition)
    end

    # Filter by user role type (STI column)
    def apply_role_filter(result)
      return result if params[:role].blank?

      role_type = ROLE_TYPE_MAPPING[params[:role].to_s.downcase]
      return result if role_type.blank?

      result.where(type: role_type)
    end

    # Filter users flagged for duplicate review
    def apply_needs_review_filter(result)
      return result unless ActiveModel::Type::Boolean.new.cast(params[:needs_review])

      result.where(needs_duplicate_review: true)
    end

    # Filter by guardian/dependent relationship status
    def apply_relationship_filter(result)
      return result if params[:relationship].blank?

      case params[:relationship].to_s.downcase
      when 'guardian'
        guardian_ids = GuardianRelationship.select(:guardian_id).distinct
        result.where(id: guardian_ids)
      when 'dependent'
        dependent_ids = GuardianRelationship.select(:dependent_id).distinct
        result.where(id: dependent_ids)
      else
        result
      end
    end

    # Apply sorting with safe column validation
    def apply_sorting(result)
      sort_column = params[:sort].presence
      sort_direction = params[:direction]&.downcase == 'desc' ? 'DESC' : 'ASC'

      if sort_column.present? && SORTABLE_COLUMNS.include?(sort_column)
        result.order(Arel.sql("#{sort_column} #{sort_direction}"))
      else
        # Default sorting: by type, then by name
        result.order(:type, :last_name, :first_name)
      end
    end

    def handle_filter_error(error)
      Rails.logger.error "Error applying user filters: #{error.message}"
      Rails.logger.error error.backtrace.join("\n")
      failure("Error applying filters: #{error.message}", scope)
    end
  end
end
