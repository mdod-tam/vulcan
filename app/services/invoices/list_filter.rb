# frozen_string_literal: true

module Invoices
  # The admin invoice list filters. The page and its CSV export use the same query; only the page
  # is paginated.
  #
  # Dates are read on an explicit basis: "period" finds invoices whose coverage overlaps the dates, and
  # "payment" finds invoices paid on those dates. The basis never changes meaning when an invoice is paid.
  class ListFilter
    STATUSES = {
      'pending' => 'invoice_pending', 'approved' => 'invoice_approved',
      'paid' => 'invoice_paid', 'withdrawn' => 'invoice_cancelled'
    }.freeze
    DATE_BASES = { 'period' => 'Invoice period', 'payment' => 'Payment date' }.freeze

    attr_reader :errors

    def initialize(params)
      @params = params
      @errors = []
    end

    def call
      scope = Invoice.includes(:vendor, :paid_by).order(created_at: :desc, id: :desc)
      scope = scope.where(status: STATUSES[@params[:status]]) if STATUSES.key?(@params[:status])
      scope = scope.where(vendor_id: @params[:vendor_id]) if @params[:vendor_id].present?
      date_filter(scope)
    end

    def date_basis
      DATE_BASES.key?(@params[:date_basis]) ? @params[:date_basis] : 'period'
    end

    private

    def date_filter(scope)
      first = typed_date(:from, 'From')&.in_time_zone
      after_last = typed_date(:through, 'Through')&.in_time_zone&.tomorrow
      return payment_dates(scope, first, after_last) if date_basis == 'payment'

      # Coverage runs from start_date up to end_date, exclusive for new invoices.
      scope = scope.where('end_date > ?', first) if first
      after_last ? scope.where(start_date: ...after_last) : scope
    end

    def payment_dates(scope, first, after_last)
      scope = scope.where(payment_date: first..) if first
      after_last ? scope.where(payment_date: ...after_last) : scope
    end

    def typed_date(key, label)
      value = @params[key]
      return if value.blank?

      DateInputNormalizer.normalize(value).tap do |date|
        @errors << "#{label} date is not a valid date. Enter it as MM/DD/YYYY." unless date
      end
    end
  end
end
