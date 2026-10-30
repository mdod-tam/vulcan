# frozen_string_literal: true

module Reports
  # Counts and chart data for the admin reports page, for the current and previous fiscal years. Each figure is
  # computed on first read, so a section the page leaves out costs no queries.
  class FiscalYearReport
    DISABILITY_TYPES = Users::Constituent::DISABILITY_TYPES
    PERIODS = %i[current previous].freeze

    attr_reader :today

    # @param today [Date] The date the fiscal years and referral periods are measured from
    def initialize(today: Date.current)
      @today = today
    end

    def current_fy_label = FiscalYear.label_for_start_year(current_start_year)
    def previous_fy_label = FiscalYear.label_for_start_year(current_start_year - 1)

    PERIODS.each do |period|
      define_method(:"#{period}_fy_applications") { application_counts(period)[:created] }
      define_method(:"#{period}_fy_draft_applications") { application_counts(period)[:drafts] }

      define_method(:"#{period}_fy_vouchers") { voucher_counts(period)[:issued] }
      define_method(:"#{period}_fy_active_vouchers") { voucher_counts(period)[:active] }
      define_method(:"#{period}_fy_expired_vouchers") { voucher_counts(period)[:expired] }
      define_method(:"#{period}_fy_voucher_value") { voucher_counts(period)[:value] }

      define_method(:"#{period}_fy_trainings") { memo(:"#{period}_trainings") { TrainingSession.where(created_at: range(period)).count } }
      define_method(:"#{period}_fy_evaluations") { memo(:"#{period}_evaluations") { Evaluation.where(created_at: range(period)).count } }
      define_method(:"#{period}_fy_training_status_counts") { status_counts(TrainingSession, period) }
      define_method(:"#{period}_fy_evaluation_status_counts") { status_counts(Evaluation, period) }

      DISABILITY_TYPES.each do |type|
        define_method(:"#{period}_fy_#{type}_disability_count") { disability_counts(period)[type] }
      end
      define_method(:"#{period}_fy_total_disability_applications") { disability_counts(period)[:total] }
    end

    def active_vendors
      memo(:active_vendors) { Users::Vendor.joins(:voucher_transactions).distinct.count }
    end

    def recent_active_vendors
      memo(:recent_active_vendors) do
        Users::Vendor.joins(:voucher_transactions).where(voucher_transactions: { created_at: 1.month.ago.. }).distinct.count
      end
    end

    # The share of vendors with a transaction in the last 30 days, as a percentage.
    def recent_active_vendor_percentage
      return 0.0 if active_vendors.zero?

      recent_active_vendors.to_f / active_vendors * 100
    end

    def training_requests_count
      memo(:training_requests_count) { Application.with_pending_training_request.count }
    end

    def evaluation_requests_count
      memo(:evaluation_requests_count) { Application.with_pending_evaluation_request.count }
    end

    def applications_chart_data
      PERIODS.index_with do |period|
        { 'Applications Created' => application_counts(period)[:created], 'Draft Applications' => application_counts(period)[:drafts] }
      end
    end

    def vouchers_chart_data
      PERIODS.index_with do |period|
        counts = voucher_counts(period)
        { 'Vouchers Issued' => counts[:issued], 'Active Unredeemed' => counts[:active], 'Expired' => counts[:expired] }
      end
    end

    # Disability counts by type for the comparison chart.
    def disability_chart_data(period)
      DISABILITY_TYPES.to_h { |type| [type.capitalize, public_send(:"#{period}_fy_#{type}_disability_count") || 0] }
    end

    # Issued, active and expired voucher counts for the compact chart.
    def voucher_status_chart_data(period)
      { 'Issued' => public_send(:"#{period}_fy_vouchers"),
        'Active' => public_send(:"#{period}_fy_active_vouchers") || 0,
        'Expired' => public_send(:"#{period}_fy_expired_vouchers") || 0 }
    end

    def services_chart_data
      PERIODS.index_with do |period|
        { 'Training Sessions' => public_send(:"#{period}_fy_trainings"), 'Evaluation Sessions' => public_send(:"#{period}_fy_evaluations") }
      end
    end

    # Referral sources of applicants, each counted once however many applications they filed.
    def referral_month_data
      referral_sources(:month, today.beginning_of_month.beginning_of_day..today.end_of_month.end_of_day)
    end

    def referral_quarter_data
      referral_sources(:quarter, today.beginning_of_quarter.beginning_of_day..today.end_of_quarter.end_of_day)
    end

    def referral_ytd_data
      referral_sources(:ytd, FiscalYear.time_range(FiscalYear.start_date_for(current_start_year), today))
    end

    def referral_prior_year_data
      referral_sources(:prior_year, range(:previous))
    end

    def referral_month_label = today.strftime('%B %Y')
    def referral_quarter_label = "Q#{FiscalYear.quarter_for(today)} #{current_fy_label}"
    def referral_ytd_label = "#{current_fy_label} YTD"
    def referral_prior_year_label = previous_fy_label

    private

    def memo(key)
      @memo ||= {}
      @memo.fetch(key) { @memo[key] = yield }
    end

    def current_start_year
      @current_start_year ||= FiscalYear.current_start_year(on: today)
    end

    def start_year(period)
      period == :current ? current_start_year : current_start_year - 1
    end

    def range(period)
      FiscalYear.time_range(FiscalYear.start_date_for(start_year(period)), FiscalYear.end_date_for(start_year(period)))
    end

    def application_counts(period)
      memo(:"#{period}_applications") do
        created = Application.where(created_at: range(period))
        { created: created.count, drafts: created.where(status: :draft).count }
      end
    end

    def voucher_counts(period)
      memo(:"#{period}_vouchers") do
        issued = Voucher.where(issued_at: range(period))
        { issued: issued.count, active: issued.where(status: :active).count, expired: issued.where(status: :expired).count,
          value: issued.sum(:initial_value) }
      end
    end

    def status_counts(model, period)
      memo(:"#{period}_#{model.name}_statuses") do
        raw_counts = model.where(created_at: range(period)).group(:status).count

        model.statuses.keys.index_with do |status|
          raw_counts[status] || raw_counts[model.statuses.fetch(status)] || 0
        end
      end
    end

    # Each user contributes once per period, and a user can have several disabilities.
    def disability_counts(period)
      memo(:"#{period}_disabilities") do
        user_ids = Application.where.not(status: :draft).where(created_at: range(period)).pluck(:user_id).uniq
        users = User.where(id: user_ids)
        counts = DISABILITY_TYPES.index_with { |type| users.where("#{type}_disability": true).count }
        any_disability = DISABILITY_TYPES.map { |type| "#{type}_disability = ?" }.join(' OR ')
        counts.merge(total: users.where(any_disability, *([true] * DISABILITY_TYPES.size)).count)
      end
    end

    def referral_sources(key, created_range)
      memo(:"referral_#{key}") do
        user_ids = Application.where.not(status: :draft).where(created_at: created_range).pluck(:user_id).uniq
        next({}) if user_ids.empty?

        User.where(id: user_ids).group("COALESCE(NULLIF(referral_source, ''), 'Not Specified')").count
            .transform_keys { |source| source || 'Not Specified' }
      end
    end
  end
end
