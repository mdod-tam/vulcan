# frozen_string_literal: true

require 'test_helper'

module Admin
  module Icanconnect
    class FinancialHistoryTest < ActionDispatch::IntegrationTest
      include IcanconnectTestSupport

      setup do
        FeatureFlag.disable!(:vouchers_enabled)
        @admin = create(:admin)
        @application = create(:application, :approved, :with_all_proofs, equipment_needs_initialized_at: Time.current)
        need = create(:equipment_need, application: @application, disability_setup_group: 'deaf')
        group = Equipment::Bidding.new(actor: @admin).create!(number: 'HISTORY-BID', needs: [{ id: need.id, lock_version: need.lock_version, quantity: 1 }])
        @order = award(group, number: 'HISTORY-PO', price: '100.00')
        @unit = @order.equipment_items.sole
        @writer = ::Icanconnect::FilingWriter.new(actor: @admin)
        sign_in_as(@admin, bypass_mfa_enrollment: true)
      end

      test 'device history shows the original award and saved price and receipt changes with actor and time' do
        ordering = Equipment::Ordering.new(actor: @admin)
        ordering.mark_sent!(order: @order, sent_at: 2.days.ago.to_date, expected_version: @order.lock_version)
        Equipment::Shipment.new(actor: @admin).call(rows: [{ id: @unit.id, lock_version: @unit.lock_version }],
                                                    attributes: { shipped_at: 1.day.ago.to_date, tracking_number: 'FINANCE-HISTORY' })
        @unit.reload
        @writer.update_evidence!(record: @unit, attributes: { unit_cost: '125.00', delivered_on: 1.day.ago.to_date, installed_on: 1.day.ago.to_date },
                                 lock_version: @unit.lock_version)
        original_receipt = Event.where(auditable: @unit, action: 'icc_financial_evidence_updated').sole
        @writer.update_evidence!(record: @unit, attributes: { unit_cost: '130.00', delivered_on: Date.current, installed_on: Date.current },
                                 lock_version: @unit.lock_version)
        other_unit = create(:equipment_item, purchase_order: @order)
        @writer.update_evidence!(record: other_unit, attributes: { unit_cost: '999.00' }, lock_version: other_unit.lock_version)
        unrelated = Event.find_by!(auditable: other_unit, action: 'equipment_purchase_cost_recorded')
        events = @unit.equipment_history.to_a
        prices = events.select { |event| event.action == 'equipment_purchase_cost_recorded' }.sort_by(&:id)
        assert_equal([[100, 125], [125, 130]], prices.map { |event| event.field_change_pairs.fetch('unit_cost').map(&:to_d) })
        assert_nil original_receipt.metadata.dig('before', 'delivered_on')
        assert_equal 1.day.ago.to_date.iso8601, original_receipt.reload.metadata.dig('after', 'delivered_on')
        assert_equal 1.day.ago.to_date.iso8601, original_receipt.metadata.dig('after', 'installed_on')
        get edit_admin_icanconnect_financial_record_path("EquipmentItem:#{@unit.id}")
        assert_response :success
        assert_select '#financial-constituents', text: "Constituent: #{@application.constituent_full_name}"
        assert_select 'a.btn.btn-outline[href=?]', admin_dashboard_path, text: 'Back to Dashboard'
        assert_select 'a.btn.btn-outline[href=?]', admin_icanconnect_filing_prep_path, text: 'Back to Filing Preparation'
        assert_select 'a[href=?]', edit_admin_equipment_item_path(@unit), text: 'View device details'
        assert_select 'a[href=?]', admin_application_path(@application), text: 'View application'
        assert_select '#financial-history', text: /PO recorded/
        assert_select '#financial-history', text: /\$100\.00/
        assert_select '#financial-history', text: /\$125\.00.*\$130\.00/m
        assert_select '#financial-history', text: /Date received|Delivered on/
        assert_select '#financial-history', text: /\$999\.00/, count: 0
        assert_history(events)
        application_events = Applications::AuditLogBuilder.new(@application).build_deduplicated_audit_logs
        events.each { |event| assert_includes application_events, event }
        assert_not_includes application_events, unrelated
      end

      test 'PO charge history preserves initial amounts and invoice dates and excludes another order' do
        path = admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}")
        patch path, params: { finance: { shipping_cost: 10, tax_cost: 2, other_cost: 0, invoice_total: 112, invoice_on: 1.day.ago.to_date },
                              lock_version: @order.lock_version }
        assert_redirected_to edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}")
        initial = Event.where(auditable: @order, action: 'icc_financial_evidence_updated').sole
        patch path, params: { finance: { shipping_cost: 12, tax_cost: 3, invoice_total: 115, invoice_on: Date.current },
                              lock_version: @order.reload.lock_version }
        assert_redirected_to edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}")
        other = create(:purchase_order)
        @writer.update_evidence!(record: other, attributes: { vendor_invoice_number: 'UNRELATED-ORDER-INVOICE' }, lock_version: other.lock_version)
        assert_nil initial.metadata.dig('before', 'shipping_cost')
        assert_equal 10, initial.reload.metadata.dig('after', 'shipping_cost').to_d
        assert_equal 2, initial.metadata.dig('after', 'tax_cost').to_d
        assert_equal 1.day.ago.to_date.iso8601, initial.metadata.dig('after', 'invoice_on')
        get edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}")
        assert_response :success
        assert_select '#financial-constituents', text: "Constituent: #{@application.constituent_full_name}"
        assert_select '#financial-history', text: /Shipping cost:.*\$10\.00.*\$12\.00/m
        assert_select '#financial-history', text: /Tax cost:.*\$2\.00.*\$3\.00/m
        assert_select '#financial-history', text: /UNRELATED-ORDER-INVOICE/, count: 0
        assert_history(@order.equipment_history.to_a)
      end

      test 'assessment and training histories show their own initial and changed rates' do
        records = [create(:evaluation, application: @application), create(:training_session, application: @application)]
        records.each do |record|
          @writer.update_evidence!(record: record, attributes: { funding_source: 'mat', hourly_rate: 45, billable_hours: 2 }, lock_version: record.lock_version)
          initial = Event.where(auditable: record, action: 'icc_financial_evidence_updated').sole
          @writer.update_evidence!(record: record, attributes: { hourly_rate: 50, billable_hours: 3 }, lock_version: record.lock_version)
          assert_nil initial.metadata.dig('before', 'hourly_rate')
          assert_equal 45, initial.reload.metadata.dig('after', 'hourly_rate').to_d
          assert_equal 2, initial.metadata.dig('after', 'billable_hours').to_d
          get edit_admin_icanconnect_financial_record_path("#{record.class.name}:#{record.id}")
          assert_response :success
          assert_select '#financial-constituents', text: "Constituent: #{@application.constituent_full_name}"
          assert_select '#financial-history', text: /Hourly rate:.*\$45\.00.*\$50\.00/m
          assert_select '#financial-history', text: /Billable hours:.*2.*3/m
          events = Event.where(auditable: record).to_a
          assert_history(events)
          logs = Applications::AuditLogBuilder.new(@application).build_deduplicated_audit_logs
          events.each { |event| assert_includes logs, event }
        end
      end

      test 'service bill history shows the entered amount date and later price change without unrelated evidence' do
        _order, unit = icc_order_with_unit
        freeze_time do
          %w[ORIGINAL-BILL SECOND-BILL].each do |reference|
            post admin_icanconnect_financial_records_path(application_id: unit.application_id), params: {
              expense: { equipment_item_id: unit.id, category: 'travel', service_date: Date.current.strftime('%m/%d/%Y'),
                         vendor_name: 'Travel provider', amount: '25', vendor_invoice_number: reference }
            }
            assert_response :redirect
          end
        end
        expenses = unit.application.application_service_expenses
        events = Applications::AuditLogBuilder.new(unit.application).build_deduplicated_audit_logs
        bills_recorded = events.grep(Event).select { |event| event.action == 'icc_service_expense_recorded' }
        assert_equal expenses.ids.sort, bills_recorded.map(&:auditable_id).sort
        expense = expenses.find_by!(vendor_invoice_number: 'ORIGINAL-BILL')
        initial = Event.find_by!(auditable: expense, action: 'icc_service_expense_recorded')
        @writer.update_evidence!(record: expense, attributes: { amount: 30, vendor_invoice_number: 'REVISED-BILL' }, lock_version: expense.lock_version)
        assert_equal 25, initial.field_change_pairs.fetch('amount').last.to_d
        assert_equal Date.current.iso8601, initial.field_change_pairs.fetch('service_date').last
        get edit_admin_icanconnect_financial_record_path("ApplicationServiceExpense:#{expense.id}")
        assert_response :success
        assert_select '#financial-constituents', text: "Constituent: #{unit.application.constituent_full_name}"
        assert_select '#financial-history', text: /Service bill recorded/
        assert_select '#financial-history', text: /Amount:.*\$25\.00.*\$30\.00/m
        assert_select '#financial-history', text: /Service date:/
        assert_select '#financial-history', text: /ORIGINAL-BILL.*REVISED-BILL|REVISED-BILL.*ORIGINAL-BILL/m
        assert_select '#financial-history', text: /HISTORY-PO/, count: 0
        assert_history(Event.where(auditable: expense).to_a)
      end

      test 'reordering a detached device audits its actual previous price and PO date and rolls back if that audit fails' do
        @unit.update!(po_assigned_at: 2.days.ago)
        Equipment::Correction.new(actor: @admin).update_item!(item: @unit, attributes: {}, expected_version: @unit.lock_version,
                                                              reason: 'Use another supplier', operation: 'detach')
        group = Equipment::Bidding.new(actor: @admin).create!(number: 'REORDER-HISTORY', items: [{ id: @unit.id, lock_version: @unit.reload.lock_version }])
        before = @unit.reload.attributes
        log = AuditEventService.method(:log)
        refuse_reorder_audit = lambda do |**attributes|
          raise ActiveRecord::RecordInvalid, Event.new if attributes[:action] == 'equipment_item_reordered'

          log.call(**attributes)
        end
        assert_no_difference ['PurchaseOrder.count', 'Event.count'] do
          AuditEventService.stub(:log, refuse_reorder_audit) do
            assert_raises(ActiveRecord::RecordInvalid) { award(group, number: 'REORDER-PO', price: '150.00') }
          end
        end
        assert_equal before, @unit.reload.attributes
        assert group.reload.open?
        order = award(group, number: 'REORDER-PO', price: '150.00')
        event = Event.where(auditable: @unit, action: 'equipment_item_reordered').sole
        assert_equal [100, 150], event.field_change_pairs.fetch('unit_cost').map(&:to_d)
        assert_equal before.fetch('po_assigned_at').iso8601, Time.zone.parse(event.field_change_pairs.fetch('po_assigned_at').first).iso8601
        assert_equal @unit.reload.po_assigned_at.iso8601, Time.zone.parse(event.field_change_pairs.fetch('po_assigned_at').last).iso8601
        assert_equal [@unit.id], event.metadata.fetch('equipment_item_ids')
        assert_equal [order.id], event.metadata.fetch('purchase_order_ids')
        get edit_admin_icanconnect_financial_record_path("EquipmentItem:#{@unit.id}")
        assert_response :success
        assert_select '#financial-history', text: /Device reordered/
        assert_select '#financial-history', text: /\$100\.00.*\$150\.00/m
        assert_history([event])
        assert_includes Applications::AuditLogBuilder.new(@application).build_deduplicated_audit_logs, event
      end

      test 'PO financial editor names each beneficiary once when several devices share an application' do
        Current.set(user: @admin) { @application.user.update!(first_name: 'Riley', last_name: 'Carter') }
        other_application = create(:application, :approved, :with_all_proofs, user: create(:constituent, first_name: 'Mina', last_name: 'Perez'))
        create(:equipment_item, application: @application, purchase_order: @order)
        create(:equipment_item, application: other_application, purchase_order: @order)

        get edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}")

        assert_response :success
        assert_select '#financial-constituents', text: 'Constituents: Riley Carter and Mina Perez'
        assert_select 'a[href=?]', admin_purchase_order_path(@order), text: 'View purchase order details'
      end

      test 'stock PO financial editor identifies stock without inventing a constituent' do
        order = create(:purchase_order, purpose: :program_stock)

        get edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{order.id}")

        assert_response :success
        assert_select '#financial-constituents', text: 'For program stock.'
        assert_select 'a', text: 'View application', count: 0
      end

      private

      def award(group, number:, price:)
        lines = group.active_lines.to_a
        Equipment::Ordering.new(actor: @admin).call(bid_group: group, expected_version: group.lock_version,
                                                    line_versions: lines.to_h { |line| [line.id.to_s, line.lock_version] },
                                                    application_versions: equipment_bid_profile_versions(group),
                                                    purchase_order_attributes: { number: number, vendor_name: 'History supplier' },
                                                    line_unit_costs: lines.to_h { |line| [line.id.to_s, price] })
      end

      def assert_history(events)
        assert_select 'details#financial-history[open]' do
          assert_select 'summary', text: 'Financial history'
          assert_select 'li p', text: /#{Regexp.escape(@admin.full_name)}/
          events.each { |event| assert_select 'time[datetime=?]', event.created_at.iso8601 }
        end
      end
    end
  end
end
