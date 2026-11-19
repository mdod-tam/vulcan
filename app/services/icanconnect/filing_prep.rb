# frozen_string_literal: true

require 'csv'

module Icanconnect
  class FilingPrep
    TYPES = { 'EquipmentItem' => EquipmentItem, 'PurchaseOrder' => PurchaseOrder, 'Evaluation' => Evaluation,
              'TrainingSession' => TrainingSession, 'ApplicationServiceExpense' => ApplicationServiceExpense }.freeze
    Row = Data.define(:record, :category, :application, :source_on, :amount, :documents, :missing) do
      def key = "#{record.class.name}:#{record.id}"
      def ready? = missing.empty?
      def claimed? = record.icc_claimed?

      def review_version
        context = [record.lock_version, amount&.to_s, documents.map { |attachment| [attachment.id, attachment.blob_id] }]
        context << record.purchase_order.lock_version if record.is_a?(EquipmentItem) && record.purchase_order
        context << record.equipment_items.map { |item| [item.id, item.lock_version] }.sort if record.is_a?(PurchaseOrder) || record.is_a?(TrainingSession)
        Digest::SHA256.hexdigest(context.to_json)
      end
    end
    FINANCIAL_PRELOADS = { financial_document_attachment: :blob }.freeze
    CATEGORIES = %w[equipment purchase_order_charges assessment training installation interpretation travel].freeze

    def initialize(from:, through:, view: 'unclaimed', category: nil)
      @from = DateInputNormalizer.normalize(from)
      @through = DateInputNormalizer.normalize(through)
      raise ArgumentError, 'Choose valid start and end dates.' unless @from && @through
      raise ArgumentError, 'Choose an end date on or after the start date, within one year' if @through < @from || (@through - @from) > 366

      @view = view
      @category = category.presence
      raise ArgumentError, 'Unknown filing view' unless %w[unclaimed activity].include?(@view)
      raise ArgumentError, 'Unknown filing category' if @category && CATEGORIES.exclude?(@category)
    end

    def rows
      return @rows if @rows

      @rows = records.map { |record| self.class.row(record) }.sort_by { |row| [row.source_on, row.key] }
    end

    def category_totals
      rows.group_by(&:category).transform_values do |entries|
        known = entries.filter_map(&:amount)
        { amount: known.presence&.sum, missing: entries.count { |row| row.amount.nil? } }
      end
    end

    # Worksheet fields mirror the administrator's consumer/equipment/service/cost records.
    # This is a review worksheet; the CD supports UI/API entry, not a promised CSV import.
    def csv
      output = +''
      writer = CsvExport.new(output, headers: %w[
                               LocalRecord Category BeneficiaryApplication Beneficiary DateRequested SourceDate DatePerformed DateReceived DateInstalled
                               InvoiceDate InvoiceNumber EquipmentIDs Product ServiceProvider DurationHours BillableHours HourlyRate
                               Mileage MileageRate MileageCost Amount
                               ShippingCost TaxCost OtherCost OtherCostCategory Manufacturer Model SerialNumber IMEI PONumber VendorName
                               ApplicationDate DateOrdered POSentDate DateShipped
                               DocumentReferences Readiness ClaimPeriod ExternalFilingReference
                             ])
      rows.each { |row| writer << csv_values(row) }
      output
    end

    def self.find_record(key)
      type, id = key.to_s.split(':', 2)
      raise ArgumentError, 'Invalid cost row' unless TYPES.key?(type) && id&.match?(/\A[1-9]\d*\z/)

      TYPES.fetch(type).find(id)
    end

    def self.row(record)
      case record
      when EquipmentItem then equipment_row(record)
      when PurchaseOrder then purchase_order_row(record)
      when Evaluation, TrainingSession then service_row(record)
      when ApplicationServiceExpense then expense_row(record)
      else raise ArgumentError, 'Unsupported financial record'
      end
    end

    def self.equipment_row(item)
      missing = base_missing(item)
      missing << 'Date received by the applicant is missing' unless item.delivered_on
      missing << 'Purchase order missing' unless item.purchase_order
      documents = invoice_documents(item.purchase_order, missing)
      Row.new(item, 'equipment', item.application, item.delivered_on || item.purchase_order&.invoice_on || item.created_at.to_date,
              item.unit_cost, documents, missing_cost(item.unit_cost, missing))
    end

    def self.purchase_order_row(order)
      missing = base_missing(order)
      units = order.equipment_items.to_a
      missing << 'Enter the date each device was received before filing shared PO charges' if units.empty? || units.any? { |item| item.delivered_on.nil? }
      amount = order.shared_charge_total
      missing << 'Enter shipping, tax and other charges. Use 0 for any that do not apply' if amount.nil?
      documents = invoice_documents(order, missing)
      Row.new(order, 'purchase_order_charges', nil, units.filter_map(&:delivered_on).max || order.invoice_on || order.created_at.to_date,
              amount, documents, missing_cost(amount, missing))
    end

    def self.service_row(service)
      missing = base_missing(service)
      missing << 'Completed service report missing' unless service.status_completed?
      missing << 'Service funding details have not been recorded' unless service.funding_service_on
      training_equipment_missing(service, missing) if service.is_a?(TrainingSession)

      documents = financial_documents(service)
      missing << 'Invoice or timesheet missing' if documents.empty?
      missing << 'Invoice reference missing' if service.vendor_invoice_number.blank?
      missing << 'Billable hours must be positive' if service.hourly_rate && !service.billable_hours.to_d.positive?
      missing << "No mileage rate is set for #{service.service_source_on.strftime('%m/%d/%Y')}" if service.mileage&.positive? && service.mileage_rate.nil?
      Row.new(service, service.is_a?(Evaluation) ? 'assessment' : 'training', service.application,
              service.service_source_on,
              service.actual_service_cost, documents, missing_cost(service.actual_service_cost, missing))
    end

    def self.training_equipment_missing(service, missing)
      units = service.equipment_items.to_a
      missing << 'Choose the devices used during training' if units.empty?
      unsuitable = units.any? do |item|
        !item.delivered_on || (service.funding_service_on && item.delivered_on > service.funding_service_on)
      end
      missing << 'Confirm the devices were received before this training session' if unsuitable
    end

    def self.expense_row(expense)
      missing = base_missing(expense)
      unit = expense.equipment_item
      unless unit&.funding_source == 'icanconnect' && unit.application_id == expense.application_id && unit.delivered_on
        missing << 'Choose the ICC-funded device for this bill'
      end
      documents = financial_documents(expense)
      missing << 'Provider name missing' if expense.vendor_name.blank?
      missing << 'Invoice missing' if documents.empty?
      missing << 'Invoice reference missing' if expense.vendor_invoice_number.blank?
      Row.new(expense, expense.category, expense.application, expense.service_date, expense.amount, documents, missing_cost(expense.amount, missing))
    end

    def self.base_missing(record)
      missing = []
      missing << 'Not an ICC-funded cost' unless record.funding_source == 'icanconnect'
      missing
    end

    def self.invoice_documents(order, missing)
      return [] unless order

      missing << 'Invoice number or invoice date missing' if order.vendor_invoice_number.blank? || order.invoice_on.nil?
      missing << 'Supplier name missing' if order.vendor_name.blank?
      missing << 'Invoice total does not match the device costs and PO charges' unless order.invoice_reconciled?
      documents = financial_documents(order)
      missing << 'Supplier invoice missing' if documents.empty?
      documents
    end

    def self.financial_documents(record)
      [record.financial_document.attachment].compact
    end

    def self.document_reference(attachment)
      "evidence-#{attachment.blob_id}.pdf"
    end

    def self.missing_cost(amount, missing)
      missing << 'Actual cost missing' if amount.nil?
      missing << 'The amount to file must be greater than zero' if amount && !amount.positive?
      missing
    end

    private

    def records
      result = []
      items = EquipmentItem.arel_table
      orders = PurchaseOrder.arel_table
      if @category.nil? || @category == 'equipment'
        source = coalesce_date(items[:delivered_on], orders[:invoice_on], local_date(items[:created_at]))
        result.concat(period_scope(EquipmentItem.left_joins(:purchase_order), source)
                      .includes({ application: :user }, :product, :source_evaluation, purchase_order: [:equipment_items, FINANCIAL_PRELOADS]).to_a)
      end
      if @category.nil? || @category == 'purchase_order_charges'
        received = EquipmentItem.where(items[:purchase_order_id].eq(orders[:id])).select(items[:delivered_on].maximum).arel
        source = coalesce_date(received, orders[:invoice_on], local_date(orders[:created_at]))
        result.concat(period_scope(PurchaseOrder.all, source).includes(:equipment_items, FINANCIAL_PRELOADS).to_a)
      end
      if @category.nil? || @category == 'assessment'
        evaluations = Evaluation.arel_table
        source = coalesce_date(evaluations[:funding_service_on], local_date(evaluations[:appointment_completed_at]), local_date(evaluations[:created_at]))
        result.concat(period_scope(Evaluation.all, source).includes({ application: :user }, :evaluator, FINANCIAL_PRELOADS).to_a)
      end
      if @category.nil? || @category == 'training'
        sessions = TrainingSession.arel_table
        source = coalesce_date(sessions[:funding_service_on], local_date(sessions[:completed_at]), local_date(sessions[:created_at]))
        result.concat(period_scope(TrainingSession.all, source)
                      .includes({ application: :user }, :trainer, :product_trained_on, { equipment_items: :product }, FINANCIAL_PRELOADS).to_a)
      end
      if @category.nil? || %w[installation interpretation travel].include?(@category)
        scope = ApplicationServiceExpense.all
        scope = scope.where(category: @category) if @category
        result.concat(period_scope(scope, ApplicationServiceExpense.arel_table[:service_date])
                      .includes({ application: :user }, { equipment_item: %i[product purchase_order] }, FINANCIAL_PRELOADS).to_a)
      end
      result
    end

    def coalesce_date(*dates)
      Arel::Nodes::NamedFunction.new('COALESCE', dates)
    end

    def local_date(column)
      utc = Arel::Nodes::NamedFunction.new('TIMEZONE', [Arel::Nodes.build_quoted('UTC'), column])
      local = Arel::Nodes::NamedFunction.new('TIMEZONE', [Arel::Nodes.build_quoted(Time.zone.tzinfo.name), utc])
      Arel::Nodes::NamedFunction.new('DATE', [local])
    end

    def period_scope(scope, source)
      scope = scope.where(funding_source: 'icanconnect')
      scope = scope.where(icc_claimed_at: nil) if @view == 'unclaimed'
      scope.where(source.between(@from..@through))
    end

    def csv_values(row)
      record = row.record
      documents = row.documents.map { |attachment| self.class.document_reference(attachment) }.join(';')
      [row.key, row.category, row.application&.id, row.application&.constituent_full_name,
       *csv_source_values(record, row.source_on), csv_product(record), csv_service_provider(record), record.try(:duration_hours),
       record.try(:billable_hours), record.try(:hourly_rate), record.try(:mileage), record.try(:mileage_rate), record.try(:mileage_cost), row.amount,
       *csv_order_charges(record), *csv_context_values(row), documents,
       row.ready? ? 'Ready for external review' : row.missing.join('; '), record.icc_claim_period, record.icc_external_filing_reference]
    end

    def csv_source_values(record, source_on)
      order = record.is_a?(PurchaseOrder) ? record : record.try(:purchase_order)
      requested_on = case record
                     when EquipmentItem
                       record.source_evaluation&.report_submitted_at&.to_date
                     when Evaluation, TrainingSession
                       record.created_at.to_date
                     end
      units = record.is_a?(TrainingSession) ? record.equipment_item_ids.join(';') : (record.id if record.is_a?(EquipmentItem))
      performed_on = record.is_a?(ApplicationServiceExpense) ? record.service_date : record.try(:funding_service_on)
      [requested_on, source_on, performed_on, record.try(:delivered_on), record.try(:installed_on), order&.invoice_on,
       record.try(:vendor_invoice_number) || order&.vendor_invoice_number, units]
    end

    def csv_order_charges(record)
      record.is_a?(PurchaseOrder) ? [record.shipping_cost, record.tax_cost, record.other_cost, record.other_cost_category] : [nil, nil, nil, nil]
    end

    def csv_product(record)
      record.is_a?(TrainingSession) ? record.product_trained_on&.name : record.try(:product)&.name
    end

    def csv_service_provider(record)
      case record
      when TrainingSession then record.trainer.full_name
      when Evaluation then record.evaluator.full_name
      end
    end

    def csv_context_values(row)
      record = row.record
      unit = record.is_a?(EquipmentItem) ? record : record.try(:equipment_item)
      order = record.is_a?(PurchaseOrder) ? record : unit&.purchase_order
      product = unit&.product || record.try(:product_trained_on)
      ordered_on = record.is_a?(PurchaseOrder) ? record.created_at.to_date : unit&.po_assigned_at&.to_date
      [product&.manufacturer, product&.model_number, unit&.serial_number, unit&.imei, order&.number,
       record.is_a?(ApplicationServiceExpense) ? record.vendor_name : order&.vendor_name,
       row.application&.application_date&.to_date, ordered_on, order&.sent_at, unit&.shipped_at]
    end
  end
end
