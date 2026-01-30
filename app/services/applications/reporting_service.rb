# frozen_string_literal: true

module Applications
  class ReportingService < BaseService
    attr_reader :fiscal_year_override

    def initialize(fiscal_year_override = nil)
      super()
      @fiscal_year_override = fiscal_year_override
    end

    # Generate dashboard reporting data
    def generate_dashboard_data
      data = {}

      setup_fiscal_year_data(data)
      add_application_metrics(data)
      add_voucher_metrics(data)
      add_service_metrics(data)
      add_guardian_dependent_metrics(data, data[:current_fy_start], data[:current_fy_end], :current_fy)
      add_guardian_dependent_metrics(data, data[:previous_fy_start], data[:previous_fy_end], :previous_fy)
      add_vendor_metrics(data)
      add_mfr_metrics(data)
      build_chart_data(data)

      success(nil, data)
    rescue StandardError => e
      Rails.logger.error "Error generating dashboard data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating dashboard data: #{e.message}", {})
    end

    # Generate index data for the applications index page
    def generate_index_data
      data = {}

      add_basic_index_counts(data)
      add_guardian_dependent_index_counts(data)
      add_recent_notifications(data)
      status_counts = fetch_application_status_counts
      add_proof_review_metrics(data)
      add_training_requests_count(data)
      add_application_pipeline_data(data, status_counts)
      add_status_breakdown_data(data, status_counts)
      add_individual_status_counts(data, status_counts)

      success(nil, data)
    rescue StandardError => e
      Rails.logger.error "Error generating index data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating index data: #{e.message}", {})
    end

    private

    def add_guardian_dependent_metrics(data, start_date, end_date, period_key)
      # Count of guardian users created in the period
      data[:"#{period_key}_guardian_users_count"] =
        User.with_dependents
            .where(created_at: start_date..end_date)
            .count

      # Count of dependent users created in the period
      data[:"#{period_key}_dependent_users_count"] =
        User.with_guardians
            .where(created_at: start_date..end_date)
            .count

      # Count of applications for dependents (applications where user is a dependent)
      data[:"#{period_key}_dependent_applications_count"] =
        Application.joins(user: :guardian_relationships_as_dependent)
                   .where(applications: { created_at: start_date..end_date })
                   .distinct
                   .count

      # Count of applications managed by guardians
      data[:"#{period_key}_guardian_managed_applications_count"] =
        Application.where.not(managing_guardian_id: nil)
                   .where(created_at: start_date..end_date)
                   .count

      # Guardian relationship metrics
      data[:"#{period_key}_avg_dependents_per_guardian"] =
        calculate_avg_dependents_per_guardian(start_date, end_date)

      data[:"#{period_key}_multi_dependent_guardians_count"] =
        count_guardians_with_multiple_dependents(start_date, end_date)

      data
    end

    def calculate_avg_dependents_per_guardian(start_date, end_date)
      # Get count of dependents per guardian who registered in the given period
      # Fix the join reference - use the guardian_user association directly
      guardian_counts = GuardianRelationship
                        .joins(:guardian_user)
                        .where(users: { created_at: start_date..end_date })
                        .group(:guardian_id)
                        .count

      return 0 if guardian_counts.empty?

      # Calculate average
      guardian_counts.values.sum.to_f / guardian_counts.size
    end

    def count_guardians_with_multiple_dependents(start_date, end_date)
      # Count guardians who have more than one dependent
      # Fix the join reference - use the guardian_user association directly
      guardian_counts = GuardianRelationship
                        .joins(:guardian_user)
                        .where(users: { created_at: start_date..end_date })
                        .group(:guardian_id)
                        .count

      # Return count of guardians with more than one dependent
      guardian_counts.count { |_guardian_id, count| count > 1 }
    end

    def current_fiscal_year
      return fiscal_year_override if fiscal_year_override.present?

      current_date = Date.current
      current_date.month >= 7 ? current_date.year : current_date.year - 1
    end

    def fiscal_year_start
      year = current_fiscal_year
      Date.new(year, 7, 1)
    end

    def setup_fiscal_year_data(data)
      data[:current_fy] = current_fiscal_year
      data[:previous_fy] = data[:current_fy] - 1

      data[:current_fy_start] = Date.new(data[:current_fy], 7, 1)
      data[:current_fy_end] = Date.new(data[:current_fy] + 1, 6, 30)
      data[:previous_fy_start] = Date.new(data[:previous_fy], 7, 1)
      data[:previous_fy_end] = Date.new(data[:current_fy], 6, 30)
    end

    def add_application_metrics(data)
      current_range = data[:current_fy_start]..data[:current_fy_end]
      previous_range = data[:previous_fy_start]..data[:previous_fy_end]

      data[:current_fy_applications] = Application.where(created_at: current_range).count
      data[:previous_fy_applications] = Application.where(created_at: previous_range).count

      # Draft applications only (for backwards compatibility with tests)
      data[:current_fy_draft_applications] =
        Application.where(status: :draft, created_at: current_range).count
      data[:previous_fy_draft_applications] =
        Application.where(status: :draft, created_at: previous_range).count

      # Combined draft and needs_information applications (for production use)
      data[:current_fy_draft_and_needs_info_applications] =
        Application.where(status: %i[draft needs_information], created_at: current_range).count
      data[:previous_fy_draft_and_needs_info_applications] =
        Application.where(status: %i[draft needs_information], created_at: previous_range).count
    end

    def add_voucher_metrics(data)
      current_range = data[:current_fy_start]..data[:current_fy_end]
      previous_range = data[:previous_fy_start]..data[:previous_fy_end]

      data[:current_fy_vouchers] = Voucher.where(created_at: current_range).count
      data[:previous_fy_vouchers] = Voucher.where(created_at: previous_range).count

      # Unredeemed vouchers
      data[:current_fy_unredeemed_vouchers] =
        Voucher.where(created_at: current_range, status: :active).count
      data[:previous_fy_unredeemed_vouchers] =
        Voucher.where(created_at: previous_range, status: :active).count

      # Voucher values
      data[:current_fy_voucher_value] =
        Voucher.where(created_at: current_range).sum(:initial_value)
      data[:previous_fy_voucher_value] =
        Voucher.where(created_at: previous_range).sum(:initial_value)
    end

    def add_service_metrics(data)
      current_range = data[:current_fy_start]..data[:current_fy_end]
      previous_range = data[:previous_fy_start]..data[:previous_fy_end]

      # Training sessions
      data[:current_fy_trainings] = TrainingSession.where(created_at: current_range).count
      data[:previous_fy_trainings] = TrainingSession.where(created_at: previous_range).count

      # Evaluation sessions
      data[:current_fy_evaluations] = Evaluation.where(created_at: current_range).count
      data[:previous_fy_evaluations] = Evaluation.where(created_at: previous_range).count
    end

    def add_vendor_metrics(data)
      # Vendor activity
      data[:active_vendors] = Vendor.joins(:voucher_transactions).distinct.count
      data[:recent_active_vendors] = Vendor.joins(:voucher_transactions)
                                           .where(voucher_transactions: { created_at: 1.month.ago.. })
                                           .distinct.count
    end

    def add_mfr_metrics(data)
      previous_range = data[:previous_fy_start]..data[:previous_fy_end]

      # MFR Data (previous full fiscal year)
      data[:mfr_applications_approved] =
        Application.where(created_at: previous_range, status: :approved).count
      data[:mfr_vouchers_issued] = Voucher.where(created_at: previous_range).count
    end

    def build_chart_data(data)
      build_applications_chart_data(data)
      build_vouchers_chart_data(data)
      build_services_chart_data(data)
      build_mfr_chart_data(data)
      build_guardian_chart_data(data)
    end

    def build_applications_chart_data(data)
      data[:applications_chart_data] = {
        current: { 'Applications' => data[:current_fy_applications],
                   'Draft Applications' => data[:current_fy_draft_and_needs_info_applications] },
        previous: { 'Applications' => data[:previous_fy_applications],
                    'Draft Applications' => data[:previous_fy_draft_and_needs_info_applications] }
      }
    end

    def build_vouchers_chart_data(data)
      data[:vouchers_chart_data] = {
        current: { 'Vouchers Issued' => data[:current_fy_vouchers],
                   'Unredeemed Vouchers' => data[:current_fy_unredeemed_vouchers] },
        previous: { 'Vouchers Issued' => data[:previous_fy_vouchers],
                    'Unredeemed Vouchers' => data[:previous_fy_unredeemed_vouchers] }
      }
    end

    def build_services_chart_data(data)
      data[:services_chart_data] = {
        current: { 'Training Sessions' => data[:current_fy_trainings],
                   'Evaluation Sessions' => data[:current_fy_evaluations] },
        previous: { 'Training Sessions' => data[:previous_fy_trainings],
                    'Evaluation Sessions' => data[:previous_fy_evaluations] }
      }
    end

    def build_mfr_chart_data(data)
      data[:mfr_chart_data] = {
        current: { 'Applications Approved' => data[:mfr_applications_approved],
                   'Vouchers Issued' => data[:mfr_vouchers_issued] },
        previous: { 'Applications Approved' => 0, 'Vouchers Issued' => 0 } # Empty for comparison
      }
    end

    def build_guardian_chart_data(data)
      # Guardian data chart for user dashboard
      data[:guardian_chart_data] = {
        current: {
          'Guardian Users' => data[:current_fy_guardian_users_count],
          'Dependent Users' => data[:current_fy_dependent_users_count]
        },
        previous: {
          'Guardian Users' => data[:previous_fy_guardian_users_count],
          'Dependent Users' => data[:previous_fy_dependent_users_count]
        }
      }

      # Guardian applications chart for application dashboard
      data[:guardian_applications_chart_data] = {
        current: {
          'Applications for Dependents' => data[:current_fy_dependent_applications_count],
          'Guardian-Managed Applications' => data[:current_fy_guardian_managed_applications_count]
        },
        previous: {
          'Applications for Dependents' => data[:previous_fy_dependent_applications_count],
          'Guardian-Managed Applications' => data[:previous_fy_guardian_managed_applications_count]
        }
      }
    end

    def add_basic_index_counts(data)
      data[:current_fiscal_year] = current_fiscal_year
      data[:total_users_count] = User.count
      data[:ytd_constituents_count] = Application.where(created_at: fiscal_year_start..).count
      data[:open_applications_count] = Application.active.count
      data[:pending_services_count] = Application.where(status: :approved).count
    end

    def add_guardian_dependent_index_counts(data)
      # Check if these associations/scopes exist and handle nil values safely
      data[:guardian_users_count] = User.respond_to?(:with_dependents) ? User.with_dependents.count : 0
      data[:dependent_users_count] = User.respond_to?(:with_guardians) ? User.with_guardians.count : 0
      data[:dependent_applications_count] = Application.where.not(managing_guardian_id: nil).count
    rescue NoMethodError => e
      Rails.logger.error "Error in guardian relationship counts: #{e.message}"
      data[:guardian_users_count] = 0
      data[:dependent_users_count] = 0
      data[:dependent_applications_count] = 0
    end

    def add_recent_notifications(data)
      notifications = Notification.select(
        'id, recipient_id, actor_id, notifiable_id, notifiable_type, action, read_at, created_at, message_id, delivery_status, metadata'
      ).order(created_at: :desc)
                                  .limit(5)

      data[:recent_notifications] = notifications
    end

    def fetch_application_status_counts
      status_counts = Application.group(:status).count
      status_counts.default = 0 # Ensure keys exist even if count is 0
      status_counts
    end

    def add_proof_review_metrics(data)
      data[:proofs_needing_review_count] = Application
                                           .where(income_proof_status: :not_reviewed)
                                           .or(Application.where(residency_proof_status: :not_reviewed))
                                           .distinct
                                           .count

      data[:medical_certs_to_review_count] = Application
                                             .where.not(status: %i[rejected archived])
                                             .where(medical_certification_status: :received)
                                             .count
    end

    def add_training_requests_count(data)
      data[:training_requests_count] = Application
                                       .joins(:training_sessions)
                                       .where(training_sessions: { status: %i[requested scheduled confirmed] })
                                       .distinct
                                       .count
    end

    def status_count_helper(counts, status_key)
      status_int = Application.statuses[status_key]
      status_str = status_int.to_s
      counts[status_str].to_i + counts[status_int].to_i + counts[status_key.to_s].to_i
    end

    def add_application_pipeline_data(data, status_counts)
      draft_count = status_count_helper(status_counts, :draft)
      needs_info_count = status_count_helper(status_counts, :needs_information)
      draft_and_needs_info_count = draft_count + needs_info_count
      submitted_count = status_count_helper(status_counts, :submitted)
      in_review_count = status_count_helper(status_counts, :in_review)
      approved_count = status_count_helper(status_counts, :approved)
      rejected_count = status_count_helper(status_counts, :rejected)

      total_submitted_or_later = submitted_count + in_review_count + approved_count + rejected_count # Approximation
      total_in_review_or_later = in_review_count + approved_count + rejected_count # Approximation

      data[:pipeline_chart_data] = {
        'Draft' => draft_count, # For test compatibility
        'Submitted' => total_submitted_or_later, # Represents apps that passed draft
        'In Review' => total_in_review_or_later, # Represents apps that passed submission
        'Approved' => approved_count
      }

      data[:combined_pipeline_chart_data] = {
        'Draft' => draft_and_needs_info_count,
        'Submitted' => total_submitted_or_later,
        'In Review' => total_in_review_or_later,
        'Approved' => approved_count
      }
    end

    def add_status_breakdown_data(data, status_counts)
      draft_count = status_count_helper(status_counts, :draft)
      needs_info_count = status_count_helper(status_counts, :needs_information)
      draft_and_needs_info_count = draft_count + needs_info_count
      submitted_count = status_count_helper(status_counts, :submitted)
      in_review_count = status_count_helper(status_counts, :in_review)
      approved_count = status_count_helper(status_counts, :approved)
      rejected_count = status_count_helper(status_counts, :rejected)

      in_progress_combined_count = submitted_count + in_review_count # Combine for 'In Progress'

      data[:status_chart_data] = {
        'Draft' => draft_count, # For test compatibility
        'In Progress' => in_progress_combined_count,
        'Approved' => approved_count,
        'Rejected' => rejected_count
      }

      data[:combined_status_chart_data] = {
        'Draft' => draft_and_needs_info_count,
        'In Progress' => in_progress_combined_count,
        'Approved' => approved_count,
        'Rejected' => rejected_count
      }
    end

    def add_individual_status_counts(data, status_counts)
      draft_count = status_count_helper(status_counts, :draft)
      needs_info_count = status_count_helper(status_counts, :needs_information)
      draft_and_needs_info_count = draft_count + needs_info_count
      submitted_count = status_count_helper(status_counts, :submitted)
      in_review_count = status_count_helper(status_counts, :in_review)
      approved_count = status_count_helper(status_counts, :approved)
      rejected_count = status_count_helper(status_counts, :rejected)

      in_progress_combined_count = submitted_count + in_review_count # Combine for 'In Progress'

      data[:draft_count] = draft_count
      data[:draft_and_needs_info_count] = draft_and_needs_info_count
      data[:submitted_count] = submitted_count
      data[:in_review_count] = in_review_count
      data[:approved_count] = approved_count
      data[:rejected_count] = rejected_count
      data[:in_progress_count] = in_progress_combined_count # Keep for consistency if used directly
    end
  end
end
