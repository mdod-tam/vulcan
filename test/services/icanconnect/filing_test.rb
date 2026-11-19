# frozen_string_literal: true

require 'test_helper'

module Icanconnect
  class FilingTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    setup do
      @admin = create(:admin)
    end

    test 'unit costs and shared charges are separate and exact-row marking retains historical activity' do
      po, unit = icc_order_with_unit
      prep = FilingPrep.new(from: Date.current, through: Date.current)
      assert_equal 2, prep.rows.size
      assert_equal 165, prep.rows.sum(&:amount)
      assert_equal({ amount: 150, missing: 0 }, prep.category_totals['equipment'])
      assert_equal({ amount: 15, missing: 0 }, prep.category_totals['purchase_order_charges'])
      assert prep.rows.all?(&:ready?)
      assert_includes prep.csv, 'ICC-INVOICE'
      exported = CSV.parse(prep.csv, headers: true)
      unit_row = exported.find { |row| row['LocalRecord'] == "EquipmentItem:#{unit.id}" }
      charges_row = exported.find { |row| row['LocalRecord'] == "PurchaseOrder:#{po.id}" }
      assert_nil unit_row['DatePerformed']
      assert_equal Date.current.iso8601, unit_row['DateReceived']
      assert_nil unit_row['ShippingCost']
      assert_nil unit_row['TaxCost']
      assert_equal 10, charges_row['ShippingCost'].to_d
      assert_equal 5, charges_row['TaxCost'].to_d
      assert_equal 0, charges_row['OtherCost'].to_d
      FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(unit)], period: 'Test period', external_reference: 'FEDERAL-1')
      assert unit.reload.icc_claimed?
      assert_not po.reload.icc_claimed?
      assert_equal ["PurchaseOrder:#{po.id}"], FilingPrep.new(from: Date.current, through: Date.current).rows.map(&:key)
      assert_equal 2, FilingPrep.new(from: Date.current, through: Date.current, view: 'activity').rows.size
      assert_raises(ArgumentError) { FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(unit)], period: 'Other period', external_reference: 'FEDERAL-2') }
    end

    test 'zero tax reconciles an invoice without tax and blank tax leaves the charge incomplete' do
      order, = icc_order_with_unit
      order.update!(tax_cost: nil, other_cost: 2, other_cost_category: 'Handling', invoice_total: 162)
      assert_not order.invoice_reconciled?
      assert_not FilingPrep.row(order).ready?

      order.update!(tax_cost: 0)
      assert order.invoice_reconciled?
      row = FilingPrep.row(order)
      assert row.ready?
      assert_equal 12, row.amount
    end

    test 'worksheet uses the shared typed-cell protection for Unicode and whitespace formula prefixes' do
      _order, unit = icc_order_with_unit
      unit.product.update!(name: '＝1+1')
      prep = FilingPrep.new(from: Date.current, through: Date.current)
      row = CSV.parse(prep.csv, headers: true).find { |entry| entry['LocalRecord'] == "EquipmentItem:#{unit.id}" }
      assert_equal "'＝1+1", row['Product']
      assert_equal BigDecimal('150'), row['Amount'].to_d
      assert_not row['Amount'].start_with?("'")
    end

    test 'missing actual costs and receipt stay incomplete rather than becoming zero or inferred shipment' do
      po, unit = icc_order_with_unit
      unit.update!(unit_cost: nil, delivered_on: nil)
      row = FilingPrep.row(unit.reload)
      assert_nil row.amount
      assert_includes row.missing, 'Actual cost missing'
      assert_includes row.missing, 'Date received by the applicant is missing'
      assert_raises(ArgumentError) { FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(unit)], period: 'Test', external_reference: 'X') }
      assert_not unit.reload.icc_claimed?
      assert_not FilingPrep.row(po.reload).ready?
      assert_equal({ amount: nil, missing: 1 }, FilingPrep.new(from: Date.current, through: Date.current).category_totals['equipment'])
    end

    test 'changed invoice evidence rejects a stale reviewed row and a mixed invalid set rolls back atomically' do
      po, unit = icc_order_with_unit
      stale = filing_selection(unit)
      po.update!(vendor_invoice_number: 'REVISED-INVOICE')
      assert_raises(ActiveRecord::StaleObjectError) { FilingWriter.new(actor: @admin).mark!(selections: [stale], period: 'Test', external_reference: 'X') }
      selections = [filing_selection(unit), filing_selection(po)]
      po.update!(shipping_cost: nil)
      assert_raises(ActiveRecord::StaleObjectError) { FilingWriter.new(actor: @admin).mark!(selections: selections, period: 'Test', external_reference: 'X') }
      assert_not unit.reload.icc_claimed?
      assert_not po.reload.icc_claimed?
    end

    test 'claimed amount edits and purge are blocked while a reasoned external correction is audited' do
      po, unit = icc_order_with_unit
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(unit), filing_selection(po)], period: 'Test', external_reference: 'X')
      assert_not unit.reload.update(unit_cost: 151)
      assert_raises(ActiveRecord::RecordNotDestroyed) { po.reload.financial_document.attachment.destroy! }
      assert_raises(ActiveRecord::RecordNotDestroyed) { po.reload.financial_document.purge }
      assert po.reload.financial_document.attached?
      unit.reload
      assert_raises(ArgumentError) { writer.correct!(record: unit, attributes: { unit_cost: 149 }, lock_version: unit.lock_version, reason: '', external_reference: 'CORR-1') }
      writer.correct!(record: unit, attributes: { unit_cost: 149 }, lock_version: unit.lock_version, reason: 'Supplier corrected charge', external_reference: 'CORR-1')
      assert_equal 149, unit.reload.unit_cost
      assert unit.events.exists?(action: 'icc_filed_cost_corrected')
    end

    test 'claimed PO charges protect unclaimed unit costs on the same reconciled invoice' do
      order, unit = icc_order_with_unit
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(order)], period: 'Test', external_reference: 'PO-FILED')
      assert_not unit.reload.icc_claimed?
      assert unit.icc_financial_evidence_locked?
      assert_not unit.update(unit_cost: 151)
      assert_includes unit.errors.full_messages.to_sentence, 'shared invoice evidence'
      unit.reload
      writer.correct!(record: unit, attributes: { unit_cost: 149 }, lock_version: unit.lock_version,
                      reason: 'Supplier corrected shared invoice', external_reference: 'SHARED-CORRECTION')
      assert_equal 149, unit.reload.unit_cost
      assert order.reload.icc_claimed?
      assert_not unit.icc_claimed?
    end

    test 'filed PO charges retain their receipt period until an audited date correction' do
      order, unit = icc_order_with_unit
      received_on = Date.current.beginning_of_month - 1
      order.update!(sent_at: received_on - 1)
      unit.update!(shipped_at: received_on - 1, delivered_on: received_on - 1)
      sibling = create(:equipment_item, application: unit.application, purchase_order: order, funding_source: 'icanconnect',
                                        unit_cost: 50, shipped_at: received_on - 1, delivered_on: received_on, tracking_number: 'SECOND-DELIVERY')
      order.update!(invoice_total: 215)
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(order)], period: received_on.strftime('%Y-%m'), external_reference: 'PO-CHARGES-FILED')
      assert_not sibling.reload.icc_claimed?
      assert_not sibling.update(delivered_on: Date.current)
      assert_not sibling.reload.update(delivered_on: nil)
      assert_equal received_on, FilingPrep.row(order.reload).source_on
      assert_equal ["PurchaseOrder:#{order.id}"], FilingPrep.new(from: received_on, through: received_on, view: 'activity', category: 'purchase_order_charges').rows.map(&:key)
      assert_empty FilingPrep.new(from: Date.current, through: Date.current, view: 'activity', category: 'purchase_order_charges').rows
      writer.update_evidence!(record: sibling.reload, attributes: { delivered_on: received_on, installed_on: Date.current }, lock_version: sibling.lock_version)
      assert_equal Date.current, sibling.reload.installed_on
      writer.correct!(record: sibling, attributes: { delivered_on: Date.current }, lock_version: sibling.lock_version,
                      reason: 'Corrected the constituent receipt date', external_reference: 'PO-DATE-CORRECTION')
      assert_equal Date.current, FilingPrep.row(order.reload).source_on
      assert_empty FilingPrep.new(from: received_on, through: received_on, view: 'activity', category: 'purchase_order_charges').rows
      assert_equal ["PurchaseOrder:#{order.id}"], FilingPrep.new(from: Date.current, through: Date.current, view: 'activity', category: 'purchase_order_charges').rows.map(&:key)
      correction = sibling.events.find_by!(action: 'icc_filed_cost_corrected')
      assert_equal received_on.iso8601, correction.metadata.dig('before', 'delivered_on')
      assert_equal Date.current.iso8601, correction.metadata.dig('after', 'delivered_on')
      assert_equal 'PO-DATE-CORRECTION', correction.metadata['external_filing_reference']
      assert_equal received_on.strftime('%Y-%m'), order.icc_claim_period
    end

    test 'a claimed unit protects its shared invoice while an unclaimed sibling can still ship and arrive' do
      order, unit = icc_order_with_unit
      sibling = create(:equipment_item, application: unit.application, purchase_order: order, funding_source: 'icanconnect',
                                        unit_cost: 50)
      order.update!(invoice_total: 215)
      blob_id = order.financial_document.blob.id
      FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(unit)], period: 'Test', external_reference: 'UNIT-FILED')
      assert_not order.reload.icc_claimed?
      assert order.icc_financial_evidence_locked?
      assert_not order.update(shipping_cost: 11)
      assert_not order.update(tax_cost: 6)
      order.reload
      order.financial_document = icc_blob
      assert_not order.save
      assert_equal blob_id, order.reload.financial_document.blob.id
      assert_raises(ActiveRecord::RecordNotDestroyed) { order.financial_document.purge }
      assert_not sibling.reload.update(unit_cost: 51)
      assert_not sibling.reload.destroy
      Equipment::Shipment.new(actor: @admin).call(rows: [{ id: sibling.id, lock_version: sibling.reload.lock_version }],
                                                  attributes: { shipped_at: Date.current, tracking_number: 'BACKORDER-SHIPMENT' })
      assert_equal Date.current, sibling.reload.shipped_at
      FilingWriter.new(actor: @admin).update_evidence!(record: sibling, attributes: { delivered_on: Date.current, installed_on: Date.current },
                                                       lock_version: sibling.lock_version)
      assert_equal Date.current, sibling.reload.delivered_on
      assert_equal Date.current, sibling.installed_on
      assert_not unit.reload.update(installed_on: Date.current)
      assert_includes unit.errors.full_messages.to_sentence, 'audited filing correction'
      assert unit.reload.icc_claimed?
    end

    test 'voiding a mistaken filing marker requires a reason and preserves the external correction audit' do
      order, unit = icc_order_with_unit
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(unit)], period: 'Test', external_reference: 'MISTAKEN')
      writer.correct!(record: unit, attributes: Claimable::MARK_FIELDS.index_with(nil), lock_version: unit.reload.lock_version,
                      reason: 'Cost was not included externally', external_reference: 'EXTERNAL-VOID-1')
      assert_not unit.reload.icc_claimed?
      assert unit.events.exists?(action: 'icc_filed_cost_corrected')
      assert_not order.reload.icc_claimed?
    end

    test 'a stale attachment owner cannot purge an invoice after its PO cost was filed' do
      order, = icc_order_with_unit
      stale_attachment = order.financial_document.attachment
      assert_not stale_attachment.record.icc_claimed?
      FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(order)], period: 'Test', external_reference: 'FILED-AFTER-LOAD')
      assert_raises(ActiveRecord::RecordNotDestroyed) { stale_attachment.purge }
      assert order.reload.financial_document.attached?
    end

    test 'an audited replacement retains the prior filed invoice as private supporting evidence' do
      order, unit = icc_order_with_unit
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(unit)], period: 'Test', external_reference: 'FILED')
      original_attachment = order.financial_document.attachment
      original = original_attachment.blob
      replacement = icc_blob
      writer.correct!(record: order, attributes: { financial_document: replacement }, lock_version: order.reload.lock_version,
                      reason: 'Supplier supplied corrected invoice', external_reference: 'CORRECTED-INVOICE')
      assert_equal replacement.id, order.reload.financial_document.blob.id
      assert_nothing_raised { original_attachment.purge_later }
      ActiveStorage::PurgeJob.perform_now(original)
      assert original.reload.service.exist?(original.key)
      assert_includes order.superseded_financial_documents.blobs.pluck(:id), original.id
      assert AttachmentAccess.new(original.reload).allowed?(@admin)
      assert_not AttachmentAccess.new(original).allowed?(unit.application.user)
      assert_raises(ActiveRecord::RecordNotDestroyed) { order.superseded_financial_documents.attachments.sole.purge }
      assert_equal [original.id], unit.events.find_by!(action: 'icc_cost_marked_claimed').metadata.fetch('document_blob_ids')
      prep = FilingPrep.new(from: Date.current, through: Date.current)
      assert_equal [replacement.id], prep.rows.flat_map(&:documents).map(&:blob_id).uniq
      assert_includes prep.csv, "evidence-#{replacement.id}.pdf"
      assert_not_includes prep.csv, "evidence-#{original.id}.pdf"
      Zip::File.open_buffer(DocumentPackage.build(prep, actor: @admin)) do |zip|
        assert_equal ['worksheet.csv', "evidence-#{replacement.id}.pdf"], zip.entries.map(&:name)
      end
    end

    test 'private invoice package deduplicates one shared document and excludes other roles' do
      po, unit = icc_order_with_unit
      blob = po.financial_document.blob
      assert AttachmentAccess.new(blob).allowed?(@admin)
      assert_not AttachmentAccess.new(blob).allowed?(unit.application.user)
      assert_not AttachmentAccess.new(blob).allowed?(create(:trainer))
      prep = FilingPrep.new(from: Date.current, through: Date.current)
      Zip::File.open_buffer(DocumentPackage.build(prep, actor: @admin)) do |zip|
        assert_equal ['worksheet.csv', "evidence-#{blob.id}.pdf"], zip.entries.map(&:name)
      end
    end

    test 'training reports mileage separately from its hourly charge even when device funding is mixed' do
      po, unit = icc_order_with_unit
      application = unit.application
      trainer = create(:trainer)
      application.update!(assigned_trainer: trainer)
      session = create(:training_session, :completed, application: application, trainer: trainer,
                                                      product_trained_on: unit.product, funding_source: 'icanconnect', funding_service_on: Date.current,
                                                      completed_at: Time.current, duration_hours: 2, hourly_rate: 50, billable_hours: 2, mileage: 24.5, mileage_rate: '0.725',
                                                      vendor_invoice_number: 'TRAIN-1')
      session.financial_document.attach(icc_blob)
      session.training_session_equipment_items.create!(equipment_item: unit)
      mat = create(:equipment_item, application: application, purchase_order: create(:purchase_order), delivered_on: Date.current)
      session.training_session_equipment_items.create!(equipment_item: mat)
      row = FilingPrep.row(session.reload)
      assert_equal BigDecimal('117.76'), row.amount
      assert row.ready?, row.missing.to_sentence
      prep = FilingPrep.new(from: Date.current, through: Date.current, category: 'training')
      assert_equal ["TrainingSession:#{session.id}"], prep.rows.map(&:key)
      report = CSV.parse(prep.csv, headers: true).sole
      assert_equal application.constituent_full_name, report['Beneficiary']
      assert_equal trainer.full_name, report['ServiceProvider']
      assert_equal Date.current.iso8601, report['DatePerformed']
      assert_equal 2, report['DurationHours'].to_d
      assert_equal 2, report['BillableHours'].to_d
      assert_equal 50, report['HourlyRate'].to_d
      assert_equal BigDecimal('24.5'), report['Mileage'].to_d
      assert_equal BigDecimal('0.725'), report['MileageRate'].to_d
      assert_equal BigDecimal('17.76'), report['MileageCost'].to_d
      assert_equal BigDecimal('117.76'), report['Amount'].to_d
      session.mileage = -1
      assert_not session.valid?
      assert_includes session.errors[:mileage], 'must be greater than or equal to 0'
      session.reload
      assert_equal [unit.id, mat.id].sort, report['EquipmentIDs'].split(';').map(&:to_i).sort
      assert_equal unit.product.name, report['Product']
      FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(session)], period: 'Test training', external_reference: 'TRAINING-FILED')
      assert session.reload.icc_claimed?
      assert_not po.icc_claimed?

      assert_raises(ActiveRecord::RecordInvalid) { session.equipment_item_ids = [unit.id] }
      assert_equal [unit.id, mat.id].sort, session.reload.equipment_item_ids.sort
      assert_raises(ActiveRecord::RecordInvalid) { session.equipment_items.delete(mat) }
      assert_raises(ActiveRecord::RecordNotDestroyed) { session.training_session_equipment_items.find_by!(equipment_item: mat).destroy! }

      version = session.reload.lock_version
      writer = FilingWriter.new(actor: @admin)
      writer.correct!(record: session, attributes: { equipment_item_ids: [unit.id] }, lock_version: version,
                      reason: 'Only this device was used', external_reference: 'TRAINING-DEVICES-1')
      assert_equal [unit.id], session.reload.equipment_item_ids
      assert_equal version + 1, session.lock_version
      correction = Event.where(auditable: session, action: 'icc_filed_cost_corrected').sole
      assert_includes correction.metadata['changed_fields'], 'equipment_item_ids'
      assert_equal [unit.id, mat.id].sort, correction.metadata.dig('before', 'equipment_item_ids')
      assert_equal [unit.id], correction.metadata.dig('after', 'equipment_item_ids')
      writer.correct!(record: session, attributes: { equipment_item_ids: [unit.id, mat.id] }, lock_version: session.lock_version,
                      reason: 'Both devices were used', external_reference: 'TRAINING-DEVICES-2')
      assert_equal [unit.id, mat.id].sort, session.reload.equipment_item_ids.sort
      assert_equal version + 2, session.lock_version
    end

    test 'mileage rate defaults use the service date and missing rates leave the total unknown' do
      MileageRate.create!(effective_on: Date.current.beginning_of_year, dollars_per_mile: '0.800')
      MileageRate.create!(effective_on: Date.current.prev_year.beginning_of_year, dollars_per_mile: '0.700')
      session = create(:training_session, :completed, funding_source: 'mat', completed_at: Time.current,
                                                      funding_service_on: Date.current.prev_year, hourly_rate: 100, billable_hours: 1)
      writer = FilingWriter.new(actor: @admin)
      writer.update_evidence!(record: session, attributes: { mileage: 10 }, lock_version: session.lock_version)
      assert_equal BigDecimal('0.700'), session.reload.mileage_rate
      assert_equal 107, session.actual_service_cost
      writer.update_evidence!(record: session, attributes: { mileage_rate: '' }, lock_version: session.lock_version)
      assert_nil session.reload.actual_service_cost
      assert_includes FilingPrep.row(session).missing, "No mileage rate is set for #{session.service_source_on.strftime('%m/%d/%Y')}"
      assert_no_difference -> { Event.where(auditable: session).count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          writer.update_evidence!(record: session, attributes: { mileage_rate: '0.7255' }, lock_version: session.lock_version)
        end
      end
      assert_nil session.reload.mileage_rate
    end

    test 'backdated services use the effective rate at midyear and future rate boundaries' do
      MileageRate.create!(effective_on: Date.new(2026, 1, 1), dollars_per_mile: '0.725')
      july = MileageRate.create!(effective_on: Date.new(2026, 7, 1), dollars_per_mile: '0.760')
      MileageRate.create!(effective_on: Date.new(2027, 1, 1), dollars_per_mile: '0.800')
      writer = FilingWriter.new(actor: @admin)
      sessions = {
        Date.new(2026, 6, 30) => '0.725', Date.new(2026, 7, 1) => '0.760',
        Date.new(2026, 12, 31) => '0.760', Date.new(2027, 1, 1) => '0.800'
      }.map do |date, expected|
        session = create(:training_session, :completed, funding_source: 'mat', completed_at: Time.current,
                                                        funding_service_on: date, hourly_rate: 100, billable_hours: 1)
        writer.update_evidence!(record: session, attributes: { mileage: 10 }, lock_version: session.lock_version)
        assert_equal BigDecimal(expected), session.reload.mileage_rate
        assert_equal 100 + (10 * BigDecimal(expected)).round(2), session.actual_service_cost
        session
      end
      july.update!(effective_on: Date.new(2026, 7, 2), dollars_per_mile: '0.900')
      assert_equal BigDecimal('0.760'), sessions[1].reload.mileage_rate
      assert_equal BigDecimal('107.60'), sessions[1].actual_service_cost
    end

    test 'training equipment only edits advance the reviewed version and roll back invalid replacements' do
      _order, unit = icc_order_with_unit
      session = create(:training_session, :completed, application: unit.application, completed_at: Time.current,
                                                      product_trained_on: unit.product, funding_source: 'icanconnect', funding_service_on: Date.current)
      writer = FilingWriter.new(actor: @admin)
      version = session.lock_version
      writer.update_evidence!(record: session, attributes: { equipment_item_ids: [unit.id] }, lock_version: version)
      assert_equal [unit.id], session.reload.equipment_item_ids
      assert_equal version + 1, session.lock_version
      event = Event.where(auditable: session, action: 'icc_financial_evidence_updated').sole
      assert_includes event.metadata['changed_fields'], 'equipment_item_ids'
      assert_equal [], event.metadata.dig('before', 'equipment_item_ids')
      assert_equal [unit.id], event.metadata.dig('after', 'equipment_item_ids')
      assert_raises(ActiveRecord::StaleObjectError) do
        writer.update_evidence!(record: session, attributes: { equipment_item_ids: [] }, lock_version: version)
      end

      other = create(:equipment_item)
      current_version = session.reload.lock_version
      assert_no_difference -> { Event.where(auditable: session, action: 'icc_financial_evidence_updated').count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          writer.update_evidence!(record: session, attributes: { equipment_item_ids: [other.id], mileage: 75 }, lock_version: current_version)
        end
      end
      assert_equal [unit.id], session.reload.equipment_item_ids
      assert_equal current_version, session.lock_version
      assert_nil session.mileage
    end

    test 'service eligibility validation and filing use the same recorded or fallback date' do
      application = approved_deafblind_application
      records = [
        [build(:evaluation, :completed, application: application, appointment_completed_at: Time.current, created_at: 2.days.ago,
                                        funding_source: 'icanconnect'), Date.current],
        [build(:training_session, :completed, application: application, completed_at: Time.current, funding_source: 'icanconnect'), Date.current],
        [build(:evaluation, application: application, created_at: 2.days.ago, funding_source: 'icanconnect'), 2.days.ago.to_date]
      ]
      records.each do |record, expected_date|
        observed_dates = []
        Funding.stub(:validate!, ->(_application, source:, on:) { observed_dates << on if source == 'icanconnect' }) { record.valid? }
        assert_equal [expected_date], observed_dates
        assert_equal expected_date, FilingPrep.row(record).source_on
      end
    end

    test 'assessment training and service bill filing events reach their beneficiary activity history' do
      order, unit = icc_order_with_unit
      application = unit.application
      evaluation = create(:evaluation, :completed, application: application, funding_source: 'icanconnect', funding_service_on: Date.current,
                                                   hourly_rate: 25, billable_hours: 1, vendor_invoice_number: 'ASSESSMENT-BILL')
      training = create(:training_session, :completed, application: application, product_trained_on: unit.product, completed_at: Time.current,
                                                       funding_source: 'icanconnect', funding_service_on: Date.current,
                                                       hourly_rate: 25, billable_hours: 1, vendor_invoice_number: 'TRAINING-BILL')
      training.equipment_items << unit
      expense = ApplicationServiceExpense.create!(application: application, equipment_item: unit, category: 'interpretation', service_date: Date.current,
                                                  vendor_name: 'Interpreting provider', amount: 25, vendor_invoice_number: 'INTERPRETATION-BILL')
      writer = FilingWriter.new(actor: @admin)
      records = [evaluation, training, expense]
      records.each do |record|
        record.financial_document.attach(icc_blob)
        record.reload
        amount_field = record.is_a?(ApplicationServiceExpense) ? :amount : :hourly_rate
        writer.update_evidence!(record: record, attributes: { amount_field => 30 }, lock_version: record.lock_version)
        writer.mark!(selections: [filing_selection(record)], period: 'Services', external_reference: 'SERVICE-FILING')
        writer.correct!(record: record.reload, attributes: { amount_field => 31 }, lock_version: record.lock_version,
                        reason: 'Provider corrected bill', external_reference: 'SERVICE-CORRECTION')
      end
      events = Event.where(auditable: records, action: %w[icc_financial_evidence_updated icc_cost_marked_claimed icc_filed_cost_corrected]).order(:id).to_a
      assert_equal 9, events.size
      logs = Applications::AuditLogBuilder.new(application).build_deduplicated_audit_logs
      other = create(:application, :approved, :with_all_proofs)
      other_logs = Applications::AuditLogBuilder.new(other).build_deduplicated_audit_logs
      events.each do |event|
        assert_equal [application.id], event.metadata.fetch('application_ids')
        assert_includes logs, event
        assert_not_includes other_logs, event
        assert_equal @admin.id, event.user_id
        assert event.created_at
      end
      training_events = events.select { |event| event.auditable_type == 'TrainingSession' }
      training_events.each do |event|
        assert_equal [unit.id], event.metadata.fetch('equipment_item_ids')
        assert_equal [order.id], event.metadata.fetch('purchase_order_ids')
      end
    end

    test 'worksheet exports actual device supplier and purchasing context without guessing an unknown request date' do
      order, unit = icc_order_with_unit
      unit.update!(serial_number: 'ICC-DEVICE-1', imei: '123456789012347', po_assigned_at: Time.current)
      record = CSV.parse(FilingPrep.new(from: Date.current, through: Date.current).csv, headers: true)
                  .find { |row| row['LocalRecord'] == "EquipmentItem:#{unit.id}" }
      assert_equal unit.product.manufacturer, record['Manufacturer']
      assert_equal unit.product.model_number, record['Model']
      assert_equal 'ICC-DEVICE-1', record['SerialNumber']
      assert_equal '123456789012347', record['IMEI']
      assert_equal order.number, record['PONumber']
      assert_equal order.vendor_name, record['VendorName']
      assert_equal unit.application.application_date.to_date.iso8601, record['ApplicationDate']
      assert_equal Date.current.iso8601, record['DateOrdered']
      assert_equal order.sent_at.iso8601, record['POSentDate']
      assert_equal unit.shipped_at.iso8601, record['DateShipped']
      assert_nil record['DateRequested']
    end

    test 'period queries retain incomplete date fallbacks in the local timezone and exclude other dates and categories' do
      Time.use_zone('America/New_York') do
        observed_at = Time.utc(2026, 11, 14, 2)
        application = travel_to(observed_at - 3.days) { approved_deafblind_application }
        travel_to observed_at do
          order, unit = icc_order_with_unit(application: application)
          unit.update!(delivered_on: nil)
          order.update!(invoice_on: nil)
          assessment = create(:evaluation, application: application, funding_source: 'icanconnect')
          outside = create(:evaluation, application: application, status: :cancelled, funding_source: 'icanconnect', created_at: 2.days.ago)
          trainer = create(:trainer)
          application.update!(assigned_trainer: trainer)
          training = create(:training_session, application: application, trainer: trainer, funding_source: 'icanconnect', created_at: Time.current)
          expense = ApplicationServiceExpense.create!(application: application, equipment_item: unit, category: 'travel',
                                                      service_date: Date.current, vendor_name: 'Travel provider')
          prep = FilingPrep.new(from: Date.current, through: Date.current)
          expected = [order, unit, assessment, training, expense].map { |record| "#{record.class.name}:#{record.id}" }
          assert_equal expected.sort, prep.rows.map(&:key).sort
          assert(prep.rows.all? { |row| row.source_on == Date.current })
          assert_not_includes prep.rows.map(&:key), "Evaluation:#{outside.id}"
          assert_equal ["TrainingSession:#{training.id}"], FilingPrep.new(from: Date.current, through: Date.current, category: 'training').rows.map(&:key)
          assert_equal ["ApplicationServiceExpense:#{expense.id}"], FilingPrep.new(from: Date.current, through: Date.current, category: 'travel').rows.map(&:key)
        end
      end
    end
  end
end
