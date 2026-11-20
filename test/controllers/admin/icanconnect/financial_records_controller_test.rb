# frozen_string_literal: true

require 'test_helper'

module Admin
  module Icanconnect
    class FinancialRecordsControllerTest < ActionDispatch::IntegrationTest
      include IcanconnectTestSupport

      setup do
        start_icanconnect!
        @admin = create(:admin)
        @order, @unit = icc_order_with_unit
        sign_in_as(@admin, bypass_mfa_enrollment: true)
      end

      test 'invalid external bill preserves attempted expense fields and can be corrected before evidence upload' do
        expense = { equipment_item_id: @unit.id, category: 'travel', service_date: Date.current.strftime('%m/%d/%Y'),
                    vendor_name: 'Travel provider', amount: '-1', vendor_invoice_number: 'TRAVEL-1' }
        get new_admin_icanconnect_financial_record_path(application_id: @unit.application_id)
        assert_response :success
        assert_no_difference 'ApplicationServiceExpense.count' do
          post admin_icanconnect_financial_records_path(application_id: @unit.application_id), params: { expense: expense }
        end
        assert_response :unprocessable_content
        assert_select 'select[name="expense[category]"] option[selected][value="travel"]'
        assert_select "select[name='expense[equipment_item_id]'] option[selected][value='#{@unit.id}']"
        assert_select "input[name='expense[service_date]'][value='#{Date.current.strftime('%m/%d/%Y')}']"
        assert_select 'input[name="expense[amount]"][value="-1"]'
        assert_select 'input[name="expense[vendor_invoice_number]"][value="TRAVEL-1"]'
        assert_select 'input[name="expense[vendor_name]"][value="Travel provider"]'
        assert_difference 'ApplicationServiceExpense.count', 1 do
          post admin_icanconnect_financial_records_path(application_id: @unit.application_id), params: { expense: expense.merge(amount: '25') }
        end
        assert_response :redirect
        created = @unit.application.application_service_expenses.sole
        assert_equal 25, created.amount
        assert_equal 'travel', created.category
        assert_equal 'Travel provider', created.vendor_name
        assert_equal Date.current, created.service_date
        assert_not created.financial_document.attached?
        event = Event.find_by!(auditable: created, action: 'icc_service_expense_recorded')
        assert_equal [@unit.application_id], event.metadata.fetch('application_ids')
        assert_equal [@unit.id], event.metadata.fetch('equipment_item_ids')
        assert_nil event.field_change_pairs.fetch('amount').first
        assert_equal 25, event.field_change_pairs.fetch('amount').last.to_d
        assert_includes Applications::AuditLogBuilder.new(@unit.application).build_deduplicated_audit_logs, event
        get admin_application_path(@unit.application)
        assert_response :success
        assert_select '#audit-logs', text: /Service bill recorded/
        assert_select '#audit-logs', text: /Amount:.*\$25\.00/m
      end

      test 'an unreadable service bill date stays as typed on retry and can be corrected before creation' do
        expense = { equipment_item_id: @unit.id, category: 'interpretation', service_date: '02/30/2026',
                    vendor_name: 'Interpreting provider', amount: '75.25', vendor_invoice_number: 'INTERPRET-1' }
        2.times do
          assert_no_difference 'ApplicationServiceExpense.count' do
            post admin_icanconnect_financial_records_path(application_id: @unit.application_id), params: { expense: expense }
          end
          assert_response :unprocessable_content
          assert_select 'input[name="expense[service_date]"][type=text][value="02/30/2026"]'
          assert_select 'select[name="expense[category]"] option[selected][value="interpretation"]'
          assert_select "select[name='expense[equipment_item_id]'] option[selected][value='#{@unit.id}']"
          assert_select 'input[name="expense[vendor_name]"][value="Interpreting provider"]'
          assert_select 'input[name="expense[vendor_invoice_number]"][value="INTERPRET-1"]'
        end
        assert_difference 'ApplicationServiceExpense.count', 1 do
          post admin_icanconnect_financial_records_path(application_id: @unit.application_id), params: {
            expense: expense.merge(service_date: Date.current.strftime('%m/%d/%Y'))
          }
        end
        assert_response :redirect
        bill = @unit.application.application_service_expenses.sole
        assert_equal Date.current, bill.service_date
        assert_equal BigDecimal('75.25'), bill.amount
      end

      test 'recording beneficiary receipt and installation requires the earlier shipping steps' do
        unit = create(:equipment_item, application: @unit.application, purchase_order: @order, funding_source: 'icanconnect')
        path = admin_icanconnect_financial_record_path("EquipmentItem:#{unit.id}")
        date = Date.current.strftime('%m/%d/%Y')

        patch path, params: { lock_version: unit.lock_version, finance: { delivered_on: date } }
        assert_response :unprocessable_content
        assert_select '[role="alert"]', text: /requires a recorded shipment/
        assert_nil unit.reload.delivered_on

        unit.update!(shipped_at: Date.current, tracking_number: 'SHIPMENT')
        patch path, params: { lock_version: unit.lock_version, finance: { installed_on: date } }
        assert_response :unprocessable_content
        assert_select '[role="alert"]', text: /requires a recorded delivery date/
        assert_nil unit.reload.installed_on

        patch path, params: { lock_version: unit.lock_version, finance: { delivered_on: date, installed_on: date } }
        assert_response :redirect
        assert_equal [Date.current, Date.current], unit.reload.attributes.values_at('delivered_on', 'installed_on')
      end

      test 'invalid financial edits retain attempted amounts and the submitted review version' do
        key = "EquipmentItem:#{@unit.id}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_response :success
        ['-1', 'garbage', '12.345'].each do |invalid|
          assert_no_difference 'Event.count' do
            patch admin_icanconnect_financial_record_path(key), params: { lock_version: @unit.lock_version, finance: { unit_cost: invalid } }
          end
          assert_response :unprocessable_content
          assert_select 'input[name="finance[unit_cost]"][type=text][inputmode=decimal]' do |inputs|
            assert_equal invalid, inputs.first['value']
          end
          assert_select "input[name='lock_version'][value='#{@unit.reload.lock_version}']"
          assert_equal 150, @unit.unit_cost
        end
        patch admin_icanconnect_financial_record_path(key), params: { lock_version: @unit.lock_version, finance: { unit_cost: '$1,234.50' } }
        assert_response :redirect
        assert_equal BigDecimal('1234.50'), @unit.reload.unit_cost
      end

      test 'stale financial edits show saved values and require entering a reviewed correction again' do
        writer = ::Icanconnect::FilingWriter.new(actor: @admin)
        writer.mark!(selections: [filing_selection(@unit)], period: 'Test', external_reference: 'FILED')
        version = @unit.reload.lock_version
        writer.correct!(record: @unit, attributes: { unit_cost: 149 }, lock_version: version,
                        reason: 'Supplier corrected price', external_reference: 'FIRST-CORRECTION')
        saved_version = @unit.reload.lock_version
        key = "EquipmentItem:#{@unit.id}"
        stale = { lock_version: version, finance: { unit_cost: '148' }, correction_reason: 'Old proposed change',
                  correction_reference: 'OLD-CORRECTION', void_filing_marker: '1' }
        2.times do
          patch admin_icanconnect_financial_record_path(key), params: stale
          assert_response :unprocessable_content
          assert_select '[role="alert"]', text: /saved values are shown below/
          assert_select "input[name='lock_version'][value='#{saved_version}']"
          assert_select 'input[name="finance[unit_cost]"][value="149.0"]'
          assert_select 'textarea[name="correction_reason"]', text: ''
          assert_select 'input[name="correction_reference"][value]', count: 0
          assert_select 'input[name="void_filing_marker"][checked]', count: 0
          assert_equal 149, @unit.reload.unit_cost
          assert @unit.icc_claimed?
        end
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: saved_version, finance: { unit_cost: '147' }, correction_reason: 'Reviewed new supplier amount',
          correction_reference: 'REVIEWED-CORRECTION'
        }
        assert_response :redirect
        assert_equal 147, @unit.reload.unit_cost
        assert @unit.icc_claimed?
      end

      test 'filed price corrections reject malformed amounts and retain the reviewed correction for retry' do
        ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(@unit)], period: 'Test', external_reference: 'FILED')
        original = @unit.reload.attributes
        parameters = { lock_version: @unit.lock_version, correction_reason: 'Supplier corrected the invoice amount',
                       correction_reference: 'PRICE-CORRECTION' }
        key = "EquipmentItem:#{@unit.id}"
        ['garbage', '12.345'].each do |invalid|
          assert_no_difference 'Event.count' do
            patch admin_icanconnect_financial_record_path(key), params: parameters.merge(finance: { unit_cost: invalid })
          end
          assert_response :unprocessable_content
          assert_select '[role=alert]', text: /Enter a valid price per device/
          assert_select 'input[name="finance[unit_cost]"][type=text][inputmode=decimal][value=?]', invalid
          assert_select 'textarea[name="correction_reason"]', text: parameters[:correction_reason]
          assert_select 'input[name="correction_reference"][value=?]', parameters[:correction_reference]
          assert_select "input[name='lock_version'][value='#{parameters[:lock_version]}']"
          assert_equal original, @unit.reload.attributes
        end
        assert_difference 'Event.count', 1 do
          patch admin_icanconnect_financial_record_path(key), params: parameters.merge(finance: { unit_cost: '$1,234.50' })
        end
        assert_response :redirect
        assert_equal BigDecimal('1234.50'), @unit.reload.unit_cost
        assert @unit.icc_claimed?
        correction = Event.where(auditable: @unit, action: 'icc_filed_cost_corrected').sole
        assert_equal parameters[:correction_reason], correction.metadata.fetch('correction_reason')
        assert_equal parameters[:correction_reference], correction.metadata.fetch('external_filing_reference')
        assert_equal 150, correction.metadata.dig('before', 'unit_cost').to_d
        assert_equal BigDecimal('1234.50'), correction.metadata.dig('after', 'unit_cost').to_d
        assert_not Event.exists?(auditable: @unit, action: 'equipment_purchase_cost_recorded')
      end

      test 'a stale training edit restores current equipment selection rather than the old submitted IDs' do
        session = create(:training_session, :completed, application: @unit.application, completed_at: Time.current,
                                                        product_trained_on: @unit.product, funding_source: 'mat', funding_service_on: Date.current)
        unit = create(:equipment_item, application: @unit.application, product: @unit.product)
        version = session.lock_version
        ::Icanconnect::FilingWriter.new(actor: @admin).update_evidence!(record: session, attributes: { equipment_item_ids: [@unit.id, unit.id] }, lock_version: version)
        patch admin_icanconnect_financial_record_path("TrainingSession:#{session.id}"), params: {
          lock_version: version, finance: { equipment_item_ids: [@unit.id], mileage: 75 }
        }
        assert_response :unprocessable_content
        assert_select "input[name='lock_version'][value='#{session.reload.lock_version}']"
        assert_select "input[name='finance[equipment_item_ids][]'][value='#{@unit.id}'][checked]"
        assert_select "input[name='finance[equipment_item_ids][]'][value='#{unit.id}'][checked]"
        assert_select 'input[name="finance[mileage]"][value]', count: 0
        assert_equal [@unit.id, unit.id].sort, session.equipment_item_ids.sort
      end

      test 'invoice scan recovery keeps the validation context but changes after a stale review' do
        key = "PurchaseOrder:#{@order.id}"
        version = @order.lock_version
        context = "admin/icanconnect/financial_records:PurchaseOrder:#{@order.id}:#{version}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_select "[data-document-upload-context-value='#{context}']"
        patch admin_icanconnect_financial_record_path(key), params: { lock_version: version, finance: { invoice_total: '-1' } }
        assert_response :unprocessable_content
        assert_select "[data-document-upload-context-value='#{context}']"
        ::Icanconnect::FilingWriter.new(actor: @admin).update_evidence!(record: @order, attributes: { vendor_name: 'Current supplier' }, lock_version: version)
        patch admin_icanconnect_financial_record_path(key), params: { lock_version: version, finance: { vendor_name: 'Stale supplier' } }
        assert_response :unprocessable_content
        current_context = "admin/icanconnect/financial_records:PurchaseOrder:#{@order.id}:#{@order.reload.lock_version}"
        assert_not_equal context, current_context
        assert_select "[data-document-upload-context-value='#{current_context}']"
        assert_select 'input[name="finance[vendor_name]"][value="Current supplier"]'
      end

      test 'financial upload accepts only the admin owned cleared receipt and stays private on download' do
        replacement = icc_blob
        key = "PurchaseOrder:#{@order.id}"
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: @order.lock_version, finance: { vendor_invoice_number: 'REVISED', financial_document_signed_id: replacement.signed_id }
        }
        assert_response :redirect
        assert_equal replacement.id, @order.reload.financial_document.blob.id
        get document_attachment_path(@order.financial_document.attachment)
        assert_response :success
        assert_includes response.headers['Cache-Control'], 'no-store'
        sign_in_as(@unit.application.user)
        get document_attachment_path(@order.financial_document.attachment)
        assert_response :not_found
      end

      test 'a financial receipt is rechecked after owner locks inside the attachment writer transaction' do
        replacement = icc_blob
        context_locked = false
        original_lock = ::Icanconnect::FinancialContext.method(:lock!)
        original_resolve = UploadedDocument.method(:resolve!)
        locking = lambda do |records|
          original_lock.call(records)
          context_locked = true
        end
        resolving = lambda do |input, **options|
          assert context_locked, 'Receipt acceptance must follow the canonical invoice owner locks'
          assert ActiveRecord::Base.connection.transaction_open?
          assert_equal @order.id, options.fetch(:record).id
          original_resolve.call(input, **options)
        end
        ::Icanconnect::FinancialContext.stub(:lock!, locking) do
          UploadedDocument.stub(:resolve!, resolving) do
            patch admin_icanconnect_financial_record_path("PurchaseOrder:#{@order.id}"), params: {
              lock_version: @order.lock_version,
              finance: { vendor_invoice_number: 'LOCKED-UPLOAD', financial_document_signed_id: replacement.signed_id }
            }
          end
        end
        assert_response :redirect
        assert_equal replacement.id, @order.reload.financial_document.blob.id
      end

      test 'finance can resolve omitted training equipment using only units belonging to the beneficiary' do
        trainer = create(:trainer)
        application = @unit.application
        application.update!(assigned_trainer: trainer)
        session = create(:training_session, :completed, application: application, trainer: trainer,
                                                        product_trained_on: @unit.product, completed_at: Time.current, funding_source: 'icanconnect', funding_service_on: Date.current)
        key = "TrainingSession:#{session.id}"
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.lock_version, finance: { hourly_rate: 100, billable_hours: 1, equipment_item_ids: [@unit.id] }
        }
        assert_response :redirect
        assert_equal [@unit.id], session.reload.equipment_item_ids
        other = create(:equipment_item)
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.lock_version, finance: { hourly_rate: 100, billable_hours: 1, equipment_item_ids: [other.id] }
        }
        assert_response :unprocessable_content
        assert_equal [@unit.id], session.reload.equipment_item_ids
      end

      test 'mileage uses a saved effective rate and keeps the hourly charge separate' do
        rate = MileageRate.create!(effective_on: Date.current.beginning_of_year, dollars_per_mile: '0.725')
        MileageRate.create!(effective_on: Date.current.next_year.beginning_of_year, dollars_per_mile: '0.900')
        session = create(:training_session, :completed, application: @unit.application, product_trained_on: @unit.product,
                                                        completed_at: Time.current, funding_source: 'icanconnect', funding_service_on: Date.current)
        key = "TrainingSession:#{session.id}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_select 'label[for=finance_mileage]', text: 'Mileage (miles)'
        assert_select 'input[name="finance[mileage_rate]"][value="0.725"]'
        assert_select 'input[name="finance[contractor_charge]"]', count: 0
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.lock_version, finance: { hourly_rate: '95', billable_hours: '1.5', mileage: '24.5' }
        }
        assert_response :redirect
        assert_equal BigDecimal('24.5'), session.reload.mileage
        assert_equal BigDecimal('142.5'), session.hourly_service_cost
        assert_equal BigDecimal('17.76'), session.mileage_cost
        assert_equal BigDecimal('160.26'), session.actual_service_cost
        assert_equal BigDecimal('0.725'), session.mileage_rate
        event = Event.where(auditable: session, action: 'icc_financial_evidence_updated').sole
        assert_equal @admin.id, event.user_id
        assert_nil event.metadata.dig('before', 'mileage')
        assert_equal BigDecimal('24.5'), event.metadata.dig('after', 'mileage').to_d
        assert_includes event.metadata.fetch('changed_fields'), 'mileage'
        assert_includes event.metadata.fetch('changed_fields'), 'mileage_rate'
        rate.update!(dollars_per_mile: '0.800')
        assert_equal BigDecimal('160.26'), session.reload.actual_service_cost

        assert_no_difference -> { Event.where(auditable: session, action: 'icc_financial_evidence_updated').count } do
          patch admin_icanconnect_financial_record_path(key), params: {
            lock_version: session.lock_version, finance: { mileage: '-1' }
          }
          assert_response :unprocessable_content
        end
        assert_equal BigDecimal('24.5'), session.reload.mileage
      end

      test 'finance chooses training funding independently from the devices and the ordinary application' do
        application = @unit.application
        trainer = create(:trainer)
        application.update!(assigned_trainer: trainer)
        session = create(:training_session, :completed, application: application, trainer: trainer,
                                                        product_trained_on: @unit.product, completed_at: Time.current,
                                                        funding_source: 'mat', funding_service_on: Date.current)
        key = "TrainingSession:#{session.id}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_response :success
        assert_select 'select[name="finance[funding_source]"] option[selected][value="mat"]'
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.lock_version, finance: { funding_source: 'icanconnect', hourly_rate: 100, billable_hours: 1,
                                                         vendor_invoice_number: 'TRAIN-1', equipment_item_ids: [@unit.id] }
        }
        assert_response :redirect
        assert_equal 'icanconnect', session.reload.funding_source
        assert_equal 'icanconnect', @unit.reload.funding_source
        assert_equal Date.current, session.funding_service_on
        assert_equal [key], ::Icanconnect::FilingPrep.new(from: Date.current, through: Date.current, category: 'training').rows.map(&:key)
        session.financial_document.attach(icc_blob)
        ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(session)], period: 'Test', external_reference: 'TRAIN-FILED')
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.reload.lock_version, finance: { funding_source: 'mat' },
          correction_reason: 'Service paid by MAT', correction_reference: 'EXTERNAL-VOID'
        }
        assert_response :unprocessable_content
        assert_equal 'icanconnect', session.reload.funding_source
        assert session.icc_claimed?
        assert_equal [key], ::Icanconnect::FilingPrep.new(from: Date.current, through: Date.current, view: 'activity', category: 'training').rows.map(&:key)
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: session.lock_version, finance: { funding_source: 'mat' }, void_filing_marker: '1',
          correction_reason: 'Service paid by MAT', correction_reference: 'EXTERNAL-VOID'
        }
        assert_response :redirect
        assert_equal 'mat', session.reload.funding_source
        assert_not session.icc_claimed?
        assert Event.exists?(auditable: session, action: 'icc_filed_cost_corrected')
        assert_empty ::Icanconnect::FilingPrep.new(from: Date.current, through: Date.current, category: 'training').rows
      end

      test 'filed shared invoices use reasoned corrections from an unclaimed owner editor' do
        writer = ::Icanconnect::FilingWriter.new(actor: @admin)
        writer.mark!(selections: [filing_selection(@unit)], period: 'Test', external_reference: 'FILED')
        key = "PurchaseOrder:#{@order.id}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_response :success
        assert_select '#financial-correction-help', count: 1, text: /This invoice is already part of a filing/
        assert_select 'textarea[name="correction_reason"][required][aria-describedby=financial-correction-help]'
        assert_select 'input[name="correction_reference"][required][aria-describedby~="financial-correction-reference-help"]'
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: @order.reload.lock_version, finance: { vendor_invoice_number: 'CORRECTED' },
          correction_reason: 'Supplier corrected the invoice reference', correction_reference: 'EXTERNAL-CORRECTION'
        }
        assert_response :redirect
        assert_equal 'CORRECTED', @order.reload.vendor_invoice_number
        assert @order.events.exists?(action: 'icc_filed_cost_corrected')
        assert @unit.reload.icc_claimed?
        assert_not @order.icc_claimed?
      end

      test 'receipt dates supporting filed PO charges require a correction even when the device is unclaimed' do
        received_on = Date.current.beginning_of_month - 1
        @order.update!(sent_at: received_on)
        @unit.update!(shipped_at: received_on, delivered_on: received_on)
        ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(@order)], period: 'Test', external_reference: 'PO-FILED')
        key = "EquipmentItem:#{@unit.id}"
        get edit_admin_icanconnect_financial_record_path(key)
        assert_response :success
        assert_select '#financial-correction-help', count: 1, text: /This PO’s charges have been filed using its device receipt dates/
        assert_select 'textarea[name="correction_reason"][aria-describedby=financial-correction-help]:not([required])'
        assert_select 'input[name="correction_reference"][aria-describedby~="financial-correction-reference-help"]:not([required])'
        [Date.current.strftime('%m/%d/%Y'), ''].each do |attempted|
          patch admin_icanconnect_financial_record_path(key), params: {
            lock_version: @unit.reload.lock_version, finance: { delivered_on: attempted }
          }
          assert_response :unprocessable_content
          assert_equal received_on, @unit.reload.delivered_on
          assert_select 'input[name="finance[delivered_on]"]' do |inputs|
            assert_equal attempted, inputs.sole['value'].to_s
          end
        end
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: @unit.lock_version, finance: { delivered_on: received_on.strftime('%m/%d/%Y'), installed_on: Date.current.strftime('%m/%d/%Y') }
        }
        assert_response :redirect
        assert_equal received_on, @unit.reload.delivered_on
        assert_equal Date.current, @unit.installed_on
        patch admin_icanconnect_financial_record_path(key), params: {
          lock_version: @unit.lock_version, finance: { delivered_on: Date.current.strftime('%m/%d/%Y') },
          correction_reason: 'Corrected the constituent receipt date', correction_reference: 'PO-DATE-CORRECTION'
        }
        assert_response :redirect
        assert_equal Date.current, @unit.reload.delivered_on
        assert_not @unit.icc_claimed?
        assert @order.reload.icc_claimed?
        assert @unit.events.exists?(action: 'icc_filed_cost_corrected')
      end

      test 'an unclaimed sibling records receipt dates normally while shared price changes still require a correction' do
        sibling = create(:equipment_item, application: @unit.application, product: @unit.product, purchase_order: @order,
                                          funding_source: 'icanconnect', unit_cost: 50, shipped_at: Date.current, tracking_number: 'BACKORDER')
        @order.update!(invoice_total: 215)
        ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(@unit)], period: 'Test', external_reference: 'FILED')
        key = "EquipmentItem:#{sibling.id}"
        date = Date.current.strftime('%m/%d/%Y')
        get edit_admin_icanconnect_financial_record_path(key)
        assert_response :success
        assert_select '#financial-correction-help', count: 1, text: /Receipt and installation dates can be recorded normally/
        assert_select 'textarea[name="correction_reason"][aria-describedby=financial-correction-help]:not([required])'
        assert_select 'input[name="correction_reference"][aria-describedby~="financial-correction-reference-help"]:not([required])'
        parameters = { lock_version: sibling.lock_version, finance: { unit_cost: '50.00', delivered_on: date, installed_on: date },
                       correction_reason: '', correction_reference: '' }
        patch admin_icanconnect_financial_record_path(key), params: parameters
        assert_response :redirect
        assert_equal Date.current, sibling.reload.delivered_on
        assert_equal Date.current, sibling.installed_on
        assert sibling.events.exists?(action: 'icc_financial_evidence_updated')
        assert_not sibling.events.exists?(action: 'icc_filed_cost_corrected')
        parameters[:lock_version] = sibling.lock_version
        parameters[:finance][:unit_cost] = '51'
        patch admin_icanconnect_financial_record_path(key), params: parameters
        assert_response :unprocessable_content
        assert_equal 50, sibling.reload.unit_cost
        assert_select 'input[name="finance[unit_cost]"]' do |inputs|
          assert_equal BigDecimal('51'), inputs.sole['value'].to_d
        end
        assert_select 'input[name="finance[delivered_on]"][value=?]', date
        parameters[:correction_reason] = 'Supplier corrected the shared invoice'
        patch admin_icanconnect_financial_record_path(key), params: parameters
        assert_response :unprocessable_content
        assert_equal 50, sibling.reload.unit_cost
        assert_select 'textarea[name="correction_reason"]', text: parameters[:correction_reason]
        parameters[:correction_reference] = 'EXTERNAL-CORRECTION'
        patch admin_icanconnect_financial_record_path(key), params: parameters
        assert_response :redirect
        assert_equal 51, sibling.reload.unit_cost
        assert sibling.events.exists?(action: 'icc_filed_cost_corrected')
        get edit_admin_icanconnect_financial_record_path("EquipmentItem:#{@unit.id}")
        assert_select '#financial-correction-help', count: 1 do |notices|
          assert_equal 'Filed for Test (reference FILED). To make a change, enter a reason and a claim or support ticket reference.',
                       notices.sole.text.squish
        end
        assert_select 'textarea[name="correction_reason"][required][aria-describedby=financial-correction-help]'
        assert_select 'input[name="correction_reference"][required][aria-describedby~="financial-correction-reference-help"]'
        patch admin_icanconnect_financial_record_path("EquipmentItem:#{@unit.id}"), params: {
          lock_version: @unit.reload.lock_version, finance: { installed_on: date }
        }
        assert_response :unprocessable_content
        assert_nil @unit.reload.installed_on
      end
    end
  end
end
