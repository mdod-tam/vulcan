# frozen_string_literal: true

require 'prawn'

module Seeds
  # Each example stops at a real workflow boundary, with its original event clocks intact.
  class DevelopmentEquipmentWorkflows
    include ActiveSupport::Testing::TimeHelpers

    STAGES = %i[evaluation_scheduling evaluation_scheduled needs_fulfillment awaiting_bid_award ready_to_send_po
                awaiting_shipment shipment_recorded training_scheduling training_scheduled training_completed].freeze
    TRAINING_STAGES = %i[training_scheduling training_scheduled training_completed].freeze
    # Synthetic invoice amounts for development only, not catalog prices or supplier quotes.
    ICC_PURCHASES = [
      { catalog_key: 'freedom-scientific-focus-40-blue-5th-generation-refreshable-braille-display', funding_source: 'icanconnect', unit_cost: '3595.00' },
      { catalog_key: 'apple-iphone-17', funding_source: 'mat', unit_cost: '799.00' }
    ].freeze

    def initialize(admin:, now:)
      @admin = admin
      @now = now
    end

    def call(application, stage, started_at:, icc: false)
      return unless STAGES.include?(stage)

      @application = application
      @started_at = started_at
      @icc = icc
      @purchases = purchases_for(application)
      @product = @purchases.first.fetch(:product)
      @evaluator = User.find_by!(email: 'evaluator@example.com')
      at(7) { application.request_evaluation!(actor: @admin) }
      at(10) { successful!(Applications::EvaluatorAssignment.assign(application, @evaluator, actor: @admin)) }
      @evaluation = application.evaluations.open_assigned.sole
      return if stage == :evaluation_scheduling

      appointment = stage == :evaluation_scheduled ? @now + 4.days : started_at + 15.days
      at(12) do
        successful!(Evaluations::ScheduleService.new(@evaluation, @evaluator,
                                                     evaluation_date: appointment, location: 'Constituent home', notes: 'Device assessment appointment confirmed.').call)
      end
      return if stage == :evaluation_scheduled

      at(16) { complete_evaluation!(appointment) }
      return if stage == :needs_fulfillment

      at(20) { reserve_bid! }
      return if stage == :awaiting_bid_award

      at(24) { award_bid! }
      return if stage == :ready_to_send_po

      at(26) do
        @orders.each { |order| Equipment::Ordering.new(actor: @admin).mark_sent!(order: order, sent_at: Time.current.to_date, expected_version: order.lock_version) }
      end
      return if stage == :awaiting_shipment

      at(29) { record_shipment! }
      at(30) { record_receipts! } if @icc
      return unless TRAINING_STAGES.include?(stage)

      seed_training!(stage)
    end

    private

    def purchases_for(application)
      if @icc
        ICC_PURCHASES.map { |purchase| purchase.merge(product: Product.available.find_by!(catalog_key: purchase.fetch(:catalog_key))) }
      else
        [{ product: Product.available.eligible_for_groups(application.program_disability_groups).where(category: 'devices').ordered_by_name.first!,
           funding_source: 'mat' }]
      end
    end

    def at(day, &)
      travel_to(@started_at + day.days, with_usec: true, &)
    end

    def successful!(result)
      raise "Development workflow failed: #{result.message}" unless result.success?
    end

    def complete_evaluation!(appointment)
      products_tried_inputs = @purchases.to_h do |purchase|
        [purchase.fetch(:product).id.to_s, { selected: '1', reaction: 'Satisfied' }]
      end
      params = ActionController::Parameters.new(evaluation: {
                                                  appointment_completed_at: appointment, location: 'Constituent home',
                                                  notes: 'The constituent tried the recommended device and can use it for their communication needs.',
                                                  attendees_field: @application.user.full_name,
                                                  program_disability_groups: @application.program_disability_groups,
                                                  shipping_confirmed: '1', **@application.suggested_shipping_snapshot,
                                                  recommended_product_ids: @purchases.map { |purchase| purchase.fetch(:product).id },
                                                  products_tried_inputs: products_tried_inputs
                                                })
      successful!(Evaluations::SubmissionService.new(@evaluation, params, actor: @evaluator).call)
      return unless @icc

      # Leave one completed assessment bill incomplete so staff can exercise the cost editor.
      update_financial_evidence!(@evaluation, funding_source: 'icanconnect')
    end

    def reserve_bid!
      @bids = @purchases.map do |purchase|
        need = @application.equipment_needs.remaining.find_by!(product: purchase.fetch(:product))
        suffix = @icc ? "-#{purchase.fetch(:funding_source).upcase}" : ''
        Equipment::Bidding.new(actor: @admin).create!(
          number: "DEMO-BID-#{@application.id}#{suffix}", funding_source: purchase.fetch(:funding_source),
          needs: [{ id: need.id, quantity: need.remaining_quantity, lock_version: need.lock_version }]
        )
      end
    end

    def award_bid!
      @orders = @bids.zip(@purchases).map do |bid, purchase|
        suffix = @icc ? "-#{purchase.fetch(:funding_source).upcase}" : ''
        order = Equipment::Ordering.new(actor: @admin).call(
          bid_group: bid, expected_version: bid.lock_version,
          application_versions: Equipment::Mutation.profile_versions([@application.reload]),
          line_versions: bid.active_lines.to_h { |line| [line.id.to_s, line.lock_version] },
          line_unit_costs: bid.active_lines.to_h { |line| [line.id.to_s, purchase[:unit_cost]] },
          purchase_order_attributes: { number: "DEMO-PO-#{@application.id}#{suffix}", vendor_name: 'Example equipment supplier' }
        )
        record_invoice!(order) if @icc
        order
      end
    end

    def record_shipment!
      @orders.each do |order|
        item = order.equipment_items.sole
        Equipment::Shipment.new(actor: @admin).call(rows: [{ id: item.id, lock_version: item.lock_version, serial_number: "DEMO-UNIT-#{item.id}" }],
                                                    attributes: { shipped_at: Time.current.to_date, tracking_number: "DEMO-TRACKING-#{item.id}", carrier: 'usps' })
      end
    end

    def record_invoice!(order)
      item = order.equipment_items.sole
      lines = [
        "Supplier: #{order.vendor_name}", "PO: #{order.number}",
        "Device: #{item.product.name}", "Device price: $#{item.unit_cost.to_s('F')}",
        'Shipping: $12.00; tax: $0.00; other charges: $0.00', "Total: $#{(item.unit_cost + 12).to_s('F')}"
      ]
      attributes = { vendor_invoice_number: "DEMO-INVOICE-#{order.id}", invoice_on: Time.current.to_date,
                     shipping_cost: '12.00', tax_cost: '0.00', other_cost: '0.00', invoice_total: item.unit_cost + 12,
                     financial_document: sample_financial_document("Invoice DEMO-INVOICE-#{order.id}", lines) }
      update_financial_evidence!(order, **attributes)
    end

    def record_receipts!
      @orders.each do |order|
        update_financial_evidence!(order.equipment_items.sole, delivered_on: Time.current.to_date, installed_on: Time.current.to_date)
      end
    end

    def seed_training!(stage)
      @trainer = User.find_by!(email: 'trainer@example.com')
      at(31) { successful!(Applications::TrainingRequestService.new(application: @application, current_user: @application.user).call) }
      at(34) { successful!(Applications::TrainerAssignment.assign(@application, @trainer, actor: @admin)) }
      session = @application.training_sessions.assigned_or_scheduled.sole
      return if stage == :training_scheduling

      appointment = stage == :training_scheduled ? @now + 3.days : @started_at + 39.days
      at(36) do
        successful!(TrainingSessions::ScheduleService.new(session, @trainer, scheduled_for: appointment, location: 'Constituent home').call)
      end
      return if stage == :training_scheduled

      at(40) do
        equipment_ids = @icc ? @application.equipment_items.where(funding_source: 'icanconnect').ids : []
        successful!(TrainingSessions::CompleteService.new(session, @trainer,
                                                          completed_at: appointment, duration_hours: '1.5', product_trained_on_id: @product.id,
                                                          equipment_item_ids: equipment_ids,
                                                          constituent_summary: 'Practiced placing calls and using the device’s accessibility settings.',
                                                          summary_locale: @application.user.locale).call)
        if @icc
          lines = ["Trainer: #{@trainer.full_name}", 'Billable time: 1.5 hours at $95.00; total $142.50']
          update_financial_evidence!(
            session,
            funding_source: 'icanconnect', hourly_rate: '95.00', billable_hours: '1.5',
            vendor_invoice_number: "DEMO-TRAINING-#{session.id}",
            financial_document: sample_financial_document("Training invoice DEMO-TRAINING-#{session.id}", lines)
          )
        end
      end
    end

    def update_financial_evidence!(record, **attributes)
      Icanconnect::FilingWriter.new(actor: @admin).update_evidence!(record: record, attributes: attributes, lock_version: record.lock_version)
    end

    def sample_financial_document(title, lines)
      pdf = Prawn::Document.new
      pdf.text 'DEVELOPMENT SAMPLE - NOT A REAL INVOICE', style: :bold
      pdf.text title
      pdf.text "Constituent: #{@application.user.full_name}"
      pdf.text "Date: #{Date.current.iso8601}"
      lines.each { |line| pdf.text line }
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(pdf.render), filename: 'development-sample-financial-evidence.pdf', content_type: 'application/pdf')
      DocumentScanFixtures.clear!(blob, user: @admin, purpose: :financial_evidence, slot: 'financial_document')
    end
  end
end
