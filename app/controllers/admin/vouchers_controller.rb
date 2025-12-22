# frozen_string_literal: true

module Admin
  class VouchersController < Admin::BaseController
    include Pagy::Backend
    include TurboStreamResponseHandling

    before_action :set_voucher, only: %i[show update cancel]
    before_action :require_admin!

    def index
      load_status_counts

      scope = Voucher.includes(:vendor).order(created_at: :desc)
      scope = apply_filters(scope)
      @pagy, @vouchers = pagy(scope, items: 25)

      respond_to do |format|
        format.html
        format.csv { send_vouchers_csv(@vouchers) }
      end
    end

    def show
      @transactions = @voucher.transactions.includes(:vendor)
                              .order(processed_at: :desc)

      @audit_logs = Vouchers::VoucherAuditLogBuilder.new(@voucher).build_deduplicated_audit_logs
    end

    def update
      if @voucher.update(voucher_params)
        AuditEventService.log(
          action: 'voucher_updated',
          actor: current_user,
          auditable: @voucher,
          metadata: { changes: @voucher.saved_changes }
        )
        handle_success_response(
          html_redirect_path: [:admin, @voucher],
          html_message: 'Voucher updated successfully',
          turbo_message: 'Voucher updated successfully'
        )
      else
        handle_error_response(
          html_render_action: :show,
          error_message: 'Failed to update voucher.'
        )
      end
    end

    def cancel
      if @voucher.cancel!
        AuditEventService.log(
          action: 'voucher_cancelled',
          actor: current_user,
          auditable: @voucher,
          metadata: {
            cancelled_at: Time.current.iso8601,
            notes: @voucher.notes
          }
        )
        handle_success_response(
          html_redirect_path: [:admin, @voucher],
          html_message: 'Voucher cancelled successfully',
          turbo_message: 'Voucher cancelled successfully'
        )
      else
        handle_error_response(
          html_redirect_path: [:admin, @voucher],
          error_message: 'Cannot cancel this voucher'
        )
      end
    end

    private

    def set_voucher
      @voucher = Voucher.find_by(code: params[:code] || params[:id]) || Voucher.find_by(id: params[:id])
    end

    def voucher_params
      params.expect(voucher: %i[status expiration_date notes])
    end

    def load_status_counts
      # SafeInstanceVariables concern: Provides safe_assign method for setting instance variables
      # Flow: safe_assign(key, value) -> sanitizes key and sets @key = value
      # Benefits: Prevents XSS attacks, ensures valid Ruby variable names, consistent error handling
      safe_assign(:active_vouchers_count, Voucher.where(status: :active).count)
      safe_assign(:expiring_soon_count, Voucher.expiring_soon.count)
      safe_assign(:redeemed_vouchers_count, Voucher.where(status: :redeemed).count)
      safe_assign(:unassigned_vouchers_count, Voucher.where(status: :active, vendor_id: nil).count)
    end

    def apply_filters(scope)
      scope = apply_status_filter(scope)
      scope = apply_additional_filters(scope)
      apply_date_range_filter(scope)
    end

    def apply_status_filter(scope)
      case params[:filter]
      when 'active'
        scope.where(status: :active)
      when 'expiring_soon'
        scope.expiring_soon
      when 'redeemed'
        scope.where(status: :redeemed)
      when 'unassigned'
        scope.where(status: :active, vendor_id: nil)
      else
        params[:filter].present? ? scope : scope.where(status: :active)
      end
    end

    def apply_additional_filters(scope)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(vendor_id: params[:vendor_id]) if params[:vendor_id].present?
      scope
    end

    def apply_date_range_filter(scope)
      return scope if params[:date_range].blank?

      case params[:date_range]
      when 'today'
        apply_today_filter(scope)
      when 'week'
        apply_week_filter(scope)
      when 'month'
        apply_month_filter(scope)
      when 'custom'
        apply_custom_date_filter(scope)
      else
        scope
      end
    end

    def apply_today_filter(scope)
      scope.where(created_at: Time.current.all_day)
    end

    def apply_week_filter(scope)
      scope.where(created_at: 1.week.ago.beginning_of_day..Time.current.end_of_day)
    end

    def apply_month_filter(scope)
      scope.where(created_at: 1.month.ago.beginning_of_day..Time.current.end_of_day)
    end

    def apply_custom_date_filter(scope)
      return scope unless params[:start_date].present? && params[:end_date].present?

      start_date = Date.parse(params[:start_date])
      end_date = Date.parse(params[:end_date])
      scope.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
    rescue Date::Error
      scope # Return unmodified scope if date parsing fails
    end

    def send_vouchers_csv(vouchers)
      send_data generate_csv(vouchers),
                filename: "vouchers-#{Time.current.strftime('%Y%m%d')}.csv",
                type: 'text/csv'
    end

    def generate_csv(vouchers)
      return '' if vouchers.empty?

      build_csv_content(vouchers)
    end

    def build_csv_content(vouchers)
      require 'smarter_csv'

      vouchers_data = vouchers.map { |voucher| voucher_to_hash(voucher) }

      # Use SmarterCSV to generate CSV with automatic header discovery
      temp_file = Tempfile.new(['vouchers', '.csv'])

      begin
        writer = SmarterCSV::Writer.new(temp_file.path)
        writer << vouchers_data
        writer.finalize

        temp_file.rewind
        temp_file.read
      ensure
        temp_file.close
        temp_file.unlink
      end
    end

    def voucher_to_hash(voucher)
      {
        'Code' => voucher.code,
        'Status' => voucher.status,
        'Initial Value' => voucher.initial_value,
        'Remaining Value' => voucher.remaining_value,
        'Vendor' => voucher.vendor&.business_name,
        'Created At' => format_date_time(voucher.created_at),
        'Expiration Date' => format_date(voucher.expiration_date),
        'Last Transaction' => format_date_time(voucher.transactions.last&.processed_at)
      }
    end

    def format_date_time(datetime)
      datetime&.strftime('%Y-%m-%d %H:%M:%S')
    end

    def format_date(date)
      date&.strftime('%Y-%m-%d')
    end
  end
end
