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

    # Generate index data for the applications index page (operational cards only; no chart payloads).
    def generate_index_data
      data = {}

      add_basic_index_counts(data)
      add_guardian_dependent_index_counts(data)
      add_recent_notifications(data)
      add_proof_review_metrics(data)
      add_training_requests_count(data)

      success(nil, data)
    rescue StandardError => e
      Rails.logger.error "Error generating index data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating index data: #{e.message}", {})
    end

    # B — Snapshot: applications created in current FY cohort, grouped by current status.
    def generate_index_chart_data
      start_year = current_fiscal_year
      fy_start = FiscalYear.start_date_for(start_year)
      fy_end = FiscalYear.end_date_for(start_year)
      cohort_end = [Date.current, fy_end].min
      cohort_range = FiscalYear.time_range(fy_start, cohort_end)

      status_counts = snapshot_status_counts(cohort_range)
      chart_data = status_counts.transform_keys { |status| status.to_s.humanize }

      success(nil, {
                current_fy: start_year,
                current_fy_label: FiscalYear.label_for_start_year(start_year),
                current_fy_range_label: FiscalYear.cohort_range_label(start_year: start_year, cohort_end_date: cohort_end),
                status_chart_data: chart_data,
                status_counts: status_counts
              })
    rescue StandardError => e
      Rails.logger.error "Error generating index chart data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating index chart data: #{e.message}", {})
    end

    # C — MFR throughput: lifecycle status transitions during completed fiscal years.
    def generate_mfr_reports_data
      current_start_year = current_fiscal_year
      most_recent_start_year = current_start_year - 1
      preceding_start_year = current_start_year - 2

      most_recent = build_mfr_fy_payload(most_recent_start_year)
      preceding = build_mfr_fy_payload(preceding_start_year)

      success(nil, {
                most_recent_fy: most_recent,
                preceding_fy: preceding,
                mfr_chart_data: {
                  current: most_recent[:chart_data],
                  previous: preceding[:chart_data]
                }
              })
    rescue StandardError => e
      Rails.logger.error "Error generating MFR reports data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating MFR reports data: #{e.message}", {})
    end

    private

    def snapshot_status_counts(cohort_range)
      raw = Application.where(created_at: cohort_range).group(:status).count
      Application.statuses.keys.index_with do |status_key|
        raw[status_key] || raw[status_key.to_s] || raw[Application.statuses[status_key]] || 0
      end.symbolize_keys
    end

    def build_mfr_fy_payload(fy_start_year)
      fy_start = FiscalYear.start_date_for(fy_start_year)
      fy_end = FiscalYear.end_date_for(fy_start_year)
      event_range = FiscalYear.time_range(fy_start, fy_end)
      created_range = event_range
      issued_range = event_range

      summary = {
        'Applications created during FY' => Application.where(created_at: created_range).count,
        'Draft to in progress during FY' => lifecycle_transitions(event_range, from_status: 'draft', to_status: 'in_progress'),
        'Status changed to approved during FY' => lifecycle_transitions(event_range, to_status: 'approved'),
        'Status changed to rejected during FY' => lifecycle_transitions(event_range, to_status: 'rejected')
      }

      chart_data = {
        'Approved (status changed during FY)' => summary['Status changed to approved during FY'],
        'Rejected (status changed during FY)' => summary['Status changed to rejected during FY'],
        'Vouchers issued during FY' => Voucher.where(issued_at: issued_range).count
      }

      {
        fy_start_year: fy_start_year,
        fy_label: FiscalYear.label_for_start_year(fy_start_year),
        fy_period_label: "July 1, #{fy_start_year} to June 30, #{fy_start_year + 1}",
        summary: summary,
        chart_data: chart_data
      }
    end

    def lifecycle_transitions(range, from_status: nil, to_status: nil)
      scope = ApplicationStatusChange.lifecycle.where(changed_at: range)
      scope = scope.where(from_status: from_status) if from_status
      scope = scope.where(to_status: to_status) if to_status
      scope.count
    end

    def add_guardian_dependent_metrics(data, start_date, end_date, period_key)
      period_range = fy_time_range(start_date, end_date)

      # Count of guardian users created in the period
      data[:"#{period_key}_guardian_users_count"] =
        User.with_dependents
            .where(created_at: period_range)
            .count

      # Count of dependent users created in the period
      data[:"#{period_key}_dependent_users_count"] =
        User.with_guardians
            .where(created_at: period_range)
            .count

      # Count of applications for dependents (applications where user is a dependent)
      data[:"#{period_key}_dependent_applications_count"] =
        Application.joins(user: :guardian_relationships_as_dependent)
                   .where(applications: { created_at: period_range })
                   .distinct
                   .count

      # Count of applications managed by guardians
      data[:"#{period_key}_guardian_managed_applications_count"] =
        Application.where.not(managing_guardian_id: nil)
                   .where(created_at: period_range)
                   .count

      # Guardian relationship metrics
      data[:"#{period_key}_avg_dependents_per_guardian"] =
        calculate_avg_dependents_per_guardian(start_date, end_date)

      data[:"#{period_key}_multi_dependent_guardians_count"] =
        count_guardians_with_multiple_dependents(start_date, end_date)

      data
    end

    def calculate_avg_dependents_per_guardian(start_date, end_date)
      period_range = fy_time_range(start_date, end_date)

      # Get count of dependents per guardian who registered in the given period
      # Fix the join reference - use the guardian_user association directly
      guardian_counts = GuardianRelationship
                        .joins(:guardian_user)
                        .where(users: { created_at: period_range })
                        .group(:guardian_id)
                        .count

      return 0 if guardian_counts.empty?

      # Calculate average
      guardian_counts.values.sum.to_f / guardian_counts.size
    end

    def count_guardians_with_multiple_dependents(start_date, end_date)
      period_range = fy_time_range(start_date, end_date)

      # Count guardians who have more than one dependent
      # Fix the join reference - use the guardian_user association directly
      guardian_counts = GuardianRelationship
                        .joins(:guardian_user)
                        .where(users: { created_at: period_range })
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

    def setup_fiscal_year_data(data)
      data[:current_fy] = current_fiscal_year
      data[:previous_fy] = data[:current_fy] - 1

      data[:current_fy_start] = Date.new(data[:current_fy], 7, 1)
      data[:current_fy_end] = Date.new(data[:current_fy] + 1, 6, 30)
      data[:previous_fy_start] = Date.new(data[:previous_fy], 7, 1)
      data[:previous_fy_end] = Date.new(data[:current_fy], 6, 30)
    end

    def add_application_metrics(data)
      current_range = fy_time_range(data[:current_fy_start], data[:current_fy_end])
      previous_range = fy_time_range(data[:previous_fy_start], data[:previous_fy_end])

      data[:current_fy_applications] = Application.where(created_at: current_range).count
      data[:previous_fy_applications] = Application.where(created_at: previous_range).count

      # Draft applications only (for backwards compatibility with tests)
      data[:current_fy_draft_applications] =
        Application.where(status: :draft, created_at: current_range).count
      data[:previous_fy_draft_applications] =
        Application.where(status: :draft, created_at: previous_range).count

      # Combined draft and awaiting_proof applications (for production use)
      data[:current_fy_draft_and_needs_info_applications] =
        Application.where(status: %i[draft awaiting_proof], created_at: current_range).count
      data[:previous_fy_draft_and_needs_info_applications] =
        Application.where(status: %i[draft awaiting_proof], created_at: previous_range).count
    end

    def add_voucher_metrics(data)
      current_range = fy_time_range(data[:current_fy_start], data[:current_fy_end])
      previous_range = fy_time_range(data[:previous_fy_start], data[:previous_fy_end])

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
      current_range = fy_time_range(data[:current_fy_start], data[:current_fy_end])
      previous_range = fy_time_range(data[:previous_fy_start], data[:previous_fy_end])

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
      payload = build_mfr_fy_payload(data[:previous_fy])
      data[:mfr_applications_approved] = payload[:summary]['Status changed to approved during FY']
      data[:mfr_vouchers_issued] = payload[:chart_data]['Vouchers issued during FY']
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
                   'Draft / Needs Info' => data[:current_fy_draft_and_needs_info_applications] },
        previous: { 'Applications' => data[:previous_fy_applications],
                    'Draft / Needs Info' => data[:previous_fy_draft_and_needs_info_applications] }
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
      most_recent = build_mfr_fy_payload(data[:previous_fy])
      data[:mfr_chart_data] = {
        current: most_recent[:chart_data],
        previous: {}
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
      data[:ytd_constituents_count] = Application.where(created_at: current_fy_ytd_range).count
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

    def add_proof_review_metrics(data)
      data[:proofs_needing_review_count] = Application.with_proofs_needing_review.distinct.count

      data[:medical_certs_to_review_count] = Application
                                             .where.not(status: %i[rejected archived])
                                             .where(medical_certification_status: :received)
                                             .count
    end

    def add_training_requests_count(data)
      data[:training_requests_count] = Application.with_pending_training_request.count
    end

    def fy_time_range(start_date, end_date)
      FiscalYear.time_range(start_date, end_date)
    end

    def current_fy_ytd_range
      fy_start = FiscalYear.start_date_for(current_fiscal_year)
      FiscalYear.time_range(fy_start, Date.current)
    end
  end
end
