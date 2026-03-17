# frozen_string_literal: true

module DashboardMetricsLoading # rubocop:disable Metrics/ModuleLength
  extend ActiveSupport::Concern

  # Main method to load all dashboard metrics with error handling
  # Uses Rails caching to reduce database load on frequent page visits
  # Returns a hash of metrics
  def load_dashboard_metrics
    # Cache all metrics together for 5 minutes to reduce DB queries
    Rails.cache.fetch('admin_dashboard_metrics', expires_in: 5.minutes) do
      metrics = {}

      # Load all metrics into the hash
      metrics[:open_applications_count] = Application.active.count
      metrics[:pending_services_count] = Application.where(status: :approved).count

      # Load reporting service data
      service_result = Applications::ReportingService.new.generate_index_data
      if service_result.is_a?(BaseService::Result) && service_result.success?
        service_result.data.to_h.each do |key, value|
          next if excluded_reporting_keys.include?(key.to_s)
          next if key.to_s.blank? || value.nil?

          metrics[key] = value
        end
      end
      # Load proof review counts
      metrics[:proofs_needing_review_count] = Application.where(income_proof_status: :not_reviewed)
                                                         .or(Application.where(residency_proof_status: :not_reviewed))
                                                         .distinct.count

      # Load certification review counts
      metrics[:medical_certs_to_review_count] = Application.where.not(status: %i[rejected archived])
                                                           .where(medical_certification_status: :received)
                                                           .count

      metrics[:digitally_signed_needs_review_count] = Application.where(document_signing_status: :signed)
                                                                 .where.not(medical_certification_status: :approved)
                                                                 .count

      # Load training requests count
      metrics[:training_requests_count] = calculate_training_requests_count

      # Load print queue count
      metrics[:print_queue_pending_count] = PrintQueueItem.pending.count

      metrics
    end
  rescue StandardError => e
    Rails.logger.error "Dashboard metric error: #{e.message}"
    # Return default values hash on error
    default_metric_values_hash
  end

  # Loads basic application counts that are commonly needed
  def load_simple_counts
    safe_assign(:open_applications_count, cached_count('open_apps') { Application.active.count })
    safe_assign(:pending_services_count, cached_count('pending_services') { Application.where(status: :approved).count })
  end

  # Integrates with the Applications::ReportingService for comprehensive data
  def load_reporting_service_data
    service_result = Applications::ReportingService.new.generate_index_data
    return unless service_result.is_a?(BaseService::Result) && service_result.success?

    # Extract data and set instance variables, excluding simple counts to avoid duplication
    service_result.data.to_h.each do |key, value|
      next if excluded_reporting_keys.include?(key.to_s)
      next if key.to_s.blank? || value.nil?

      instance_variable_set("@#{key}", value)
    end
  end

  # Loads additional metrics specific to admin operations
  def load_remaining_metrics
    load_proof_review_counts
    load_certification_review_counts
    load_training_request_counts
  end

  # Loads count for print queue
  def load_print_queue_count
    safe_assign(:print_queue_pending_count, cached_count('print_queue_pending') { PrintQueueItem.pending.count })
  end

  # Loads counts for proofs needing review
  def load_proof_review_counts
    proofs_count = cached_count('proofs_needing_review') do
      Application.where(income_proof_status: :not_reviewed)
                 .or(Application.where(residency_proof_status: :not_reviewed))
                 .distinct.count
    end

    safe_assign(:proofs_needing_review_count, proofs_count)
  end

  # Loads counts for medical certifications needing review
  def load_certification_review_counts
    medical_count = cached_count('medical_certs_to_review') do
      Application.where.not(status: %i[rejected archived])
                 .where(medical_certification_status: :received)
                 .count
    end

    # Count applications with digitally signed certifications needing admin review
    digitally_signed_count = cached_count('digitally_signed_needs_review') do
      Application.where(document_signing_status: :signed)
                 .where.not(medical_certification_status: :approved)
                 .count
    end

    safe_assign(:medical_certs_to_review_count, medical_count)
    safe_assign(:digitally_signed_needs_review_count, digitally_signed_count)
  end

  # Loads training request counts with fallback logic
  def load_training_request_counts
    training_count = cached_count('training_requests') { calculate_training_requests_count }
    safe_assign(:training_requests_count, training_count)
  end

  # === Fiscal Year Utilities ===

  # Loads fiscal year data and date ranges
  def load_fiscal_year_data
    current_fy = current_fiscal_year
    previous_fy = current_fy - 1

    safe_assign(:current_fy, current_fy)
    safe_assign(:previous_fy, previous_fy)
    safe_assign(:current_fiscal_year, current_fy)
    safe_assign(:current_fy_start, Date.new(current_fy, 7, 1))
    safe_assign(:current_fy_end, Date.new(current_fy + 1, 6, 30))
    safe_assign(:previous_fy_start, Date.new(previous_fy, 7, 1))
    safe_assign(:previous_fy_end, Date.new(current_fy, 6, 30))

    # Display labels using ending year short form (FY26, FY25)
    safe_assign(:current_fy_label, "FY#{(current_fy + 1).to_s[-2..]}")
    safe_assign(:previous_fy_label, "FY#{current_fy.to_s[-2..]}")
  end

  # Loads application counts by fiscal year
  def load_fiscal_year_application_counts
    load_fiscal_year_data unless @current_fy_start && @current_fy_end

    current_range = @current_fy_start..@current_fy_end
    previous_range = @previous_fy_start..@previous_fy_end

    safe_assign(:current_fy_applications, Application.where(created_at: current_range).count)
    safe_assign(:previous_fy_applications, Application.where(created_at: previous_range).count)
    safe_assign(:current_fy_draft_applications, Application.where(status: :draft, created_at: current_range).count)
    safe_assign(:previous_fy_draft_applications, Application.where(status: :draft, created_at: previous_range).count)
  end

  # Loads voucher counts by fiscal year
  def load_fiscal_year_voucher_counts
    load_fiscal_year_data unless @current_fy_start && @current_fy_end

    current_range = @current_fy_start..@current_fy_end
    previous_range = @previous_fy_start..@previous_fy_end

    safe_assign(:current_fy_vouchers, Voucher.where(created_at: current_range).count)
    safe_assign(:previous_fy_vouchers, Voucher.where(created_at: previous_range).count)
    safe_assign(:current_fy_active_vouchers, Voucher.where(created_at: current_range, status: :active).count)
    safe_assign(:previous_fy_active_vouchers, Voucher.where(created_at: previous_range, status: :active).count)
    safe_assign(:current_fy_expired_vouchers, Voucher.where(created_at: current_range, status: :expired).count)
    safe_assign(:previous_fy_expired_vouchers, Voucher.where(created_at: previous_range, status: :expired).count)
    safe_assign(:current_fy_voucher_value, Voucher.where(created_at: current_range).sum(:initial_value))
    safe_assign(:previous_fy_voucher_value, Voucher.where(created_at: previous_range).sum(:initial_value))
  end

  # Loads service counts (training sessions, evaluations) by fiscal year
  def load_fiscal_year_service_counts
    load_fiscal_year_data unless @current_fy_start && @current_fy_end

    current_range = @current_fy_start..@current_fy_end
    previous_range = @previous_fy_start..@previous_fy_end

    safe_assign(:current_fy_trainings, TrainingSession.where(created_at: current_range).count)
    safe_assign(:previous_fy_trainings, TrainingSession.where(created_at: previous_range).count)
    safe_assign(:current_fy_evaluations, Evaluation.where(created_at: current_range).count)
    safe_assign(:previous_fy_evaluations, Evaluation.where(created_at: previous_range).count)
  end

  # === Chart Data Utilities ===

  # Loads chart data for applications
  def load_applications_chart_data
    load_fiscal_year_application_counts unless @current_fy_applications

    safe_assign(:applications_chart_data, {
                  current: {
                    'Applications' => @current_fy_applications,
                    'Draft Applications' => @current_fy_draft_applications
                  },
                  previous: {
                    'Applications' => @previous_fy_applications,
                    'Draft Applications' => @previous_fy_draft_applications
                  }
                })
  end

  # Loads chart data for vouchers
  def load_vouchers_chart_data
    load_fiscal_year_voucher_counts unless @current_fy_vouchers

    safe_assign(:vouchers_chart_data, {
                  current: {
                    'Vouchers Issued' => @current_fy_vouchers,
                    'Active Unredeemed' => @current_fy_active_vouchers,
                    'Expired' => @current_fy_expired_vouchers
                  },
                  previous: {
                    'Vouchers Issued' => @previous_fy_vouchers,
                    'Active Unredeemed' => @previous_fy_active_vouchers,
                    'Expired' => @previous_fy_expired_vouchers
                  }
                })
  end

  # Loads chart data for services
  def load_services_chart_data
    load_fiscal_year_service_counts unless @current_fy_trainings

    safe_assign(:services_chart_data, {
                  current: {
                    'Training Sessions' => @current_fy_trainings,
                    'Evaluation Sessions' => @current_fy_evaluations
                  },
                  previous: {
                    'Training Sessions' => @previous_fy_trainings,
                    'Evaluation Sessions' => @previous_fy_evaluations
                  }
                })
  end

  # === Vendor and MFR Data ===

  # Loads vendor activity data
  def load_vendor_data
    safe_assign(:active_vendors, Vendor.joins(:voucher_transactions).distinct.count)
    safe_assign(:recent_active_vendors, Vendor.joins(:voucher_transactions)
                                           .where(voucher_transactions: { created_at: 1.month.ago.. })
                                           .distinct.count)
  end

  # Loads MFR (Managing for Results) data for both most recent and preceding FY
  def load_mfr_data
    load_fiscal_year_data unless @previous_fy_start && @previous_fy_end

    # Most recent concluded FY (previous_fy is the most recent complete year)
    most_recent_range = @previous_fy_start..@previous_fy_end
    safe_assign(:mfr_applications_approved, Application.where(created_at: most_recent_range, status: :approved).count)
    safe_assign(:mfr_vouchers_issued, Voucher.where(created_at: most_recent_range).count)

    # Preceding FY (the year before the most recent)
    preceding_fy = @previous_fy - 1
    preceding_fy_start = Date.new(preceding_fy, 7, 1)
    preceding_fy_end = Date.new(@previous_fy, 6, 30)
    preceding_range = preceding_fy_start..preceding_fy_end

    safe_assign(:mfr_preceding_applications_approved, Application.where(created_at: preceding_range, status: :approved).count)
    safe_assign(:mfr_preceding_vouchers_issued, Voucher.where(created_at: preceding_range).count)
    safe_assign(:preceding_fy, preceding_fy)
    safe_assign(:preceding_fy_label, "FY#{@previous_fy.to_s[-2..]}")
  end

  # Loads MFR chart data
  def load_mfr_chart_data
    load_mfr_data unless @mfr_applications_approved

    safe_assign(:mfr_chart_data, {
                  current: {
                    'Applications Approved' => @mfr_applications_approved,
                    'Vouchers Issued' => @mfr_vouchers_issued
                  },
                  previous: {
                    'Applications Approved' => @mfr_preceding_applications_approved || 0,
                    'Vouchers Issued' => @mfr_preceding_vouchers_issued || 0
                  }
                })
  end

  # === Comprehensive Chart Data Loading ===

  # Loads all chart data for reports
  def load_chart_data
    load_applications_chart_data
    load_vouchers_chart_data
    load_services_chart_data
    load_mfr_chart_data
  end

  # Disability type breakdown from submitted applications by fiscal year
  # Users can have multiple disabilities
  def load_disability_type_data
    load_fiscal_year_data unless @current_fy_start && @current_fy_end

    disability_types = %i[hearing vision speech mobility cognition]

    # Current FY disability counts
    load_disability_counts_for_period(:current_fy, @current_fy_start..@current_fy_end, disability_types)

    # Previous FY disability counts
    load_disability_counts_for_period(:previous_fy, @previous_fy_start..@previous_fy_end, disability_types)
  end

  # Helper to load disability counts for a specific time period
  def load_disability_counts_for_period(period_key, date_range, disability_types)
    user_ids = Application.where.not(status: :draft)
                          .where(created_at: date_range)
                          .pluck(:user_id).uniq
    users = User.where(id: user_ids)

    # Count each disability type
    disability_types.each do |type|
      safe_assign(:"#{period_key}_#{type}_disability_count", users.where("#{type}_disability": true).count)
    end

    # Total applications with at least one disability
    safe_assign(:"#{period_key}_total_disability_applications", users.where(
      disability_types.map { |t| "#{t}_disability = ?" }.join(' OR '),
      *([true] * disability_types.size)
    ).count)
  end

  # Referral source breakdown by different time periods
  # Follows existing pattern used in load_fiscal_year_application_counts
  def load_referral_source_data
    load_fiscal_year_data unless @current_fy_start && @current_fy_end

    current_date = Date.current

    # Define time period ranges - reusing existing @current_fy_start/@previous_fy_start
    time_periods = {
      month: { start: current_date.beginning_of_month, end: current_date.end_of_month },
      quarter: { start: calculate_fiscal_quarter_start(current_date), end: calculate_fiscal_quarter_end(current_date) },
      ytd: { start: @current_fy_start, end: current_date },
      prior_year: { start: @previous_fy_start, end: @previous_fy_end }
    }

    # Calculate referral sources for each period
    time_periods.each do |period, range|
      apps = Application.where.not(status: :draft).where(created_at: range[:start]..range[:end])
      safe_assign(:"referral_#{period}_data", calculate_referral_sources(apps))
    end

    # Store labels for display (use ending year short form: FY26, FY25)
    safe_assign(:referral_month_label, current_date.strftime('%B %Y'))
    safe_assign(:referral_quarter_label, "Q#{fiscal_quarter(current_date)} #{@current_fy_label}")
    safe_assign(:referral_ytd_label, "#{@current_fy_label} YTD")
    safe_assign(:referral_prior_year_label, @previous_fy_label)
    safe_assign(:show_prior_year_referral, full_prior_year_data?)
  end

  # Fiscal quarter boundaries for fiscal year (July 1 - June 30)
  FISCAL_QUARTERS = {
    1 => { months: [7, 8, 9], start: [0, 7, 1], end: [0, 9, 30] },
    2 => { months: [10, 11, 12], start: [0, 10, 1], end: [0, 12, 31] },
    3 => { months: [1, 2, 3], start: [1, 1, 1], end: [1, 3, 31] },
    4 => { months: [4, 5, 6], start: [1, 4, 1], end: [1, 6, 30] }
  }.freeze

  private

  # Calculate training request count with fallback logic
  def calculate_training_requests_count
    count = Notification.where(action: 'training_requested', notifiable_type: 'Application')
                        .distinct.count(:notifiable_id)

    return count unless count.zero?

    Application.joins(:training_sessions)
               .where(training_sessions: { status: %i[requested scheduled confirmed] })
               .distinct.count
  end

  # Get the current fiscal year (July 1 - June 30)
  def current_fiscal_year
    current_date = Date.current
    current_date.month >= 7 ? current_date.year : current_date.year - 1
  end

  # Get the start of the current fiscal year
  def fiscal_year_start
    year = current_fiscal_year
    Date.new(year, 7, 1)
  end

  # Safely assign instance variables with error handling
  def safe_assign(var_name, value)
    instance_variable_set("@#{var_name}", value)
  rescue StandardError => e
    Rails.logger.error "Failed to assign @#{var_name}: #{e.message}"
    instance_variable_set("@#{var_name}", 0) # Default to 0 for numeric values
  end

  # Cache count queries to reduce database load
  def cached_count(key, expires_in: 5.minutes, &)
    Rails.cache.fetch("dashboard_metrics_#{key}", expires_in: expires_in, &)
  end

  # Keys to exclude when loading reporting service data to avoid duplication
  def excluded_reporting_keys
    %w[open_applications_count pending_services_count]
  end

  # Return default metric values as a hash for load_dashboard_metrics
  def default_metric_values_hash
    {
      open_applications_count: 0,
      pending_services_count: 0,
      proofs_needing_review_count: 0,
      medical_certs_to_review_count: 0,
      digitally_signed_needs_review_count: 0,
      training_requests_count: 0,
      print_queue_pending_count: 0,
      current_fiscal_year: current_fiscal_year,
      draft_count: 0,
      submitted_count: 0,
      in_review_count: 0,
      approved_count: 0,
      rejected_count: 0,
      in_progress_count: 0,
      pipeline_chart_data: {},
      status_chart_data: {}
    }
  end

  # Calculates referral source breakdown for a given set of applications
  # Returns a hash of referral_source => count
  def calculate_referral_sources(applications)
    user_ids = applications.pluck(:user_id).uniq
    return {} if user_ids.empty?

    referral_data = User.where(id: user_ids)
                        .group("COALESCE(NULLIF(referral_source, ''), 'Not Specified')")
                        .count
    referral_data.transform_keys { |k| k || 'Not Specified' }
  end

  # Returns fiscal quarter (1-4) for a given date
  def fiscal_quarter(date)
    FISCAL_QUARTERS.find { |_, v| v[:months].include?(date.month) }&.first
  end

  # Returns start date of fiscal quarter for a given date
  def calculate_fiscal_quarter_start(date)
    fy = current_fiscal_year
    year_offset, month, day = FISCAL_QUARTERS[fiscal_quarter(date)][:start]
    Date.new(fy + year_offset, month, day)
  end

  # Returns end date of fiscal quarter for a given date
  def calculate_fiscal_quarter_end(date)
    fy = current_fiscal_year
    year_offset, month, day = FISCAL_QUARTERS[fiscal_quarter(date)][:end]
    Date.new(fy + year_offset, month, day)
  end

  # Checks if we have at least one full prior fiscal year of data
  def full_prior_year_data?
    @previous_fy_start &&
      Application.where.not(status: :draft)
                 .exists?(['created_at < ?', @previous_fy_start])
  end
end
