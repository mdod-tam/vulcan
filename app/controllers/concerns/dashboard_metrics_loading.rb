# frozen_string_literal: true

module DashboardMetricsLoading
  extend ActiveSupport::Concern

  # Main method to load all dashboard metrics with error handling
  def load_dashboard_metrics
    load_simple_counts
    load_reporting_service_data
    load_remaining_metrics
    load_print_queue_count
  rescue StandardError => e
    Rails.logger.error "Dashboard metric error: #{e.message}"
    # Set default values to prevent view errors
    set_default_metric_values
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
    safe_assign(:current_fy_unredeemed_vouchers, Voucher.where(created_at: current_range, status: :active).count)
    safe_assign(:previous_fy_unredeemed_vouchers, Voucher.where(created_at: previous_range, status: :active).count)
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
                    'Unredeemed Vouchers' => @current_fy_unredeemed_vouchers
                  },
                  previous: {
                    'Vouchers Issued' => @previous_fy_vouchers,
                    'Unredeemed Vouchers' => @previous_fy_unredeemed_vouchers
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

  # Loads MFR (Monthly Financial Report) data
  def load_mfr_data
    load_fiscal_year_data unless @previous_fy_start && @previous_fy_end

    previous_range = @previous_fy_start..@previous_fy_end
    safe_assign(:mfr_applications_approved, Application.where(created_at: previous_range, status: :approved).count)
    safe_assign(:mfr_vouchers_issued, Voucher.where(created_at: previous_range).count)
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
                    'Applications Approved' => 0,
                    'Vouchers Issued' => 0
                  }
                })
  end

  # === User and YTD Data ===

  # Loads basic user and year-to-date data
  def load_user_and_ytd_data
    safe_assign(:current_fiscal_year, current_fiscal_year)
    safe_assign(:total_users_count, User.count)
    safe_assign(:ytd_constituents_count, Application.where(created_at: fiscal_year_start..).count)
  end

  # === Comprehensive Chart Data Loading ===

  # Loads all chart data for reports
  def load_chart_data
    load_applications_chart_data
    load_vouchers_chart_data
    load_services_chart_data
    load_mfr_chart_data
  end

  private

  # Calculates training requests count with fallback logic
  def calculate_training_requests_count
    count = Notification.where(action: 'training_requested', notifiable_type: 'Application')
                        .distinct.count(:notifiable_id)

    return count unless count.zero?

    Application.joins(:training_sessions)
               .where(training_sessions: { status: %i[requested scheduled confirmed] })
               .distinct.count
  end

  # Gets the current fiscal year (July 1 - June 30)
  def current_fiscal_year
    current_date = Date.current
    current_date.month >= 7 ? current_date.year : current_date.year - 1
  end

  # Gets the start of the current fiscal year
  def fiscal_year_start
    year = current_fiscal_year
    Date.new(year, 7, 1)
  end

  # Safely assigns instance variables with error handling
  def safe_assign(var_name, value)
    instance_variable_set("@#{var_name}", value)
  rescue StandardError => e
    Rails.logger.error "Failed to assign @#{var_name}: #{e.message}"
    instance_variable_set("@#{var_name}", 0) # Default to 0 for numeric values
  end

  # Caches count queries to reduce database load
  def cached_count(key, expires_in: 5.minutes, &)
    Rails.cache.fetch("dashboard_metrics_#{key}", expires_in: expires_in, &)
  end

  # Keys to exclude when loading reporting service data to avoid duplication
  def excluded_reporting_keys
    %w[open_applications_count pending_services_count]
  end

  # Sets default values for metrics to prevent view errors
  def set_default_metric_values
    safe_assign(:open_applications_count, 0)
    safe_assign(:pending_services_count, 0)
    safe_assign(:proofs_needing_review_count, 0)
    safe_assign(:medical_certs_to_review_count, 0)
    safe_assign(:digitally_signed_needs_review_count, 0)
    safe_assign(:training_requests_count, 0)
    safe_assign(:print_queue_pending_count, 0)
    safe_assign(:current_fiscal_year, current_fiscal_year)
    safe_assign(:total_users_count, 0)
    safe_assign(:ytd_constituents_count, 0)
  end
end
