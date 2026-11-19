# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class IcanconnectWorkflowTest < ApplicationSystemTestCase
    include IcanconnectTestSupport
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      FeatureFlag.disable!(:vouchers_enabled)
      sign_in(@admin, bypass_mfa_enrollment: true)
    end

    test 'one approved application has MAT and ICC devices and ICC training costs in filing preparation' do
      MileageRate.create!(effective_on: Date.current.beginning_of_year, dollars_per_mile: '0.725')
      application = approved_deafblind_application
      _, unit = icc_order_with_unit(application: application)
      mat_unit = create(:equipment_item, application: application, funding_source: 'mat')
      session = create(:training_session, :completed, application: application, completed_at: Time.current, product_trained_on: unit.product,
                                                      funding_source: 'mat', funding_service_on: Date.current)
      session.financial_document.attach(icc_blob)

      visit admin_application_path(application)
      assert_no_link 'iCanConnect determination / service bills'
      within("#equipment-item-#{unit.id}") { assert_text 'iCanConnect' }
      within("#equipment-item-#{mat_unit.id}") { assert_text 'MAT' }
      take_screenshot('icc-mixed-device-funding', html: true, full: true)
      click_link 'Training costs and funding'
      select 'iCanConnect', from: 'Funding'
      fill_in 'Billable hours', with: '2'
      fill_in 'Hourly rate', with: '150'
      fill_in 'Mileage (miles)', with: '24.5'
      fill_in 'Invoice or timesheet reference', with: 'TRAINING-1'
      check "finance_equipment_#{unit.id}"
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal 'icanconnect', session.reload.funding_source
      assert_equal BigDecimal('24.5'), session.mileage
      assert_equal BigDecimal('0.725'), session.mileage_rate
      assert_equal 300, session.hourly_service_cost
      assert_equal BigDecimal('317.76'), session.actual_service_cost
      assert_no_field 'Contractor total charge'
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      assert_link 'Back to Filing Preparation', href: admin_icanconnect_filing_prep_path
      assert_link 'View training details', href: trainers_training_session_path(session)
      assert_link 'View application', href: admin_application_path(application)
      within('#financial-history') do
        assert_text @admin.full_name
        assert_text 'Mileage (miles): 24.5'
      end
      take_screenshot('icc-training-costs', html: true, full: true)
      page.current_window.resize_to(390, 900)
      take_screenshot('icc-training-costs-and-history-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 900)

      version = session.lock_version
      page.execute_script("document.getElementById('finance_mileage').removeAttribute('min')")
      fill_in 'Mileage (miles)', with: '-1'
      uncheck "finance_equipment_#{unit.id}"
      click_button 'Save costs and documents'
      assert_selector '[role="alert"]', text: 'Mileage must be greater than or equal to 0'
      assert_unchecked_field "finance_equipment_#{unit.id}"
      assert_equal(-1, find_field('Mileage (miles)').value.to_d)
      assert_equal [unit.id], session.reload.equipment_item_ids
      assert_equal version, session.lock_version
      take_screenshot('icc-training-devices-invalid-retry', html: true, full: true)
      fill_in 'Mileage (miles)', with: '25.5'
      check "finance_equipment_#{unit.id}"
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_checked_field "finance_equipment_#{unit.id}"
      assert_equal BigDecimal('25.5'), session.reload.mileage
      assert_equal BigDecimal('318.49'), session.actual_service_cost

      visit admin_icanconnect_filing_prep_path(category: 'training')
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      assert_text 'Training'
      assert_text application.constituent_full_name
      assert_text '$318.49'
      assert_text session.trainer.full_name
      assert_text 'Mileage: 25.5 miles'
      assert_selector "input[aria-label='Select Training session ##{session.id}']"
      take_screenshot('icc-training-filing', html: true, full: true)
    end

    test 'admin files exact equipment costs and corrects financial evidence' do
      order, unit = icc_order_with_unit
      visit admin_icanconnect_filing_prep_path
      assert_text '2 of 2 costs have the information needed for filing'
      assert_text '$150.00'
      assert_text '$15.00'
      assert_text 'Shipping: $10.00'
      assert_text 'Tax: $5.00'
      take_screenshot('icc-filing-ready', html: true, full: true)
      check "Select Device ##{unit.id}"
      fill_in 'Filing period', with: Date.current.strftime('%Y-%m')
      fill_in 'External filing reference', with: 'FEDERAL-TEST'
      accept_confirm { click_button 'Mark selected costs as filed' }
      assert_text 'Selected costs marked filed.'
      assert unit.reload.icc_claimed?
      assert_not order.reload.icc_claimed?
      assert_no_selector "input[aria-label='Select Device ##{unit.id}']"
      select 'Period activity, including filed costs', from: 'View'
      click_button 'Review period'
      assert_text 'FEDERAL-TEST'
      take_screenshot('icc-filing-activity', html: true, full: true)

      visit edit_admin_icanconnect_financial_record_path("EquipmentItem:#{unit.id}")
      version = unit.lock_version
      fill_in 'Price paid for this device', with: '12.345'
      fill_in 'Correction reason', with: 'Invoice corrected by supplier'
      fill_in 'External correction reference', with: 'FEDERAL-CORRECTION-TEST'
      click_button 'Save correction'
      assert_selector '[role="alert"]', text: 'Enter a valid price per device in dollars and cents, or leave it blank.'
      assert_field 'Price paid for this device', with: '12.345'
      assert_field 'Correction reason', with: 'Invoice corrected by supplier'
      assert_field 'External correction reference', with: 'FEDERAL-CORRECTION-TEST'
      assert_equal 150, unit.reload.unit_cost
      assert_equal version, unit.lock_version
      take_screenshot('icc-claimed-price-invalid-retry', html: true, full: true)
      fill_in 'Price paid for this device', with: '149.00'
      click_button 'Save correction'
      assert_text 'Financial evidence saved.'
      assert_equal 149, unit.reload.unit_cost
      take_screenshot('icc-claimed-cost-correction', html: true, full: true)
    end

    test 'a stale financial form shows current saved values before the admin enters changes again' do
      _order, unit = icc_order_with_unit
      visit edit_admin_icanconnect_financial_record_path("EquipmentItem:#{unit.id}")
      ::Icanconnect::FilingWriter.new(actor: @admin).update_evidence!(record: unit, attributes: { unit_cost: 149 }, lock_version: unit.lock_version)
      fill_in 'Price paid for this device', with: '148'
      click_button 'Save costs and documents'
      assert_selector '[role="alert"]', text: 'The saved values are shown below'
      assert_equal BigDecimal('149'), find_field('Price paid for this device').value.to_d
      assert_equal 149, unit.reload.unit_cost
      take_screenshot('icc-financial-stale-review', html: true, full: true)
      fill_in 'Price paid for this device', with: '147'
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal 147, unit.reload.unit_cost
      take_screenshot('icc-financial-after-review', html: true, full: true)
    end

    test 'ordinary unit prices preserve malformed entries and save a corrected dollar amount' do
      _order, unit = icc_order_with_unit
      visit edit_admin_icanconnect_financial_record_path("EquipmentItem:#{unit.id}")
      ['12.345', 'garbage'].each do |amount|
        fill_in 'Price paid for this device', with: amount
        click_button 'Save costs and documents'
        assert_selector '[role="alert"]', text: 'Enter a valid price per device in dollars and cents, or leave it blank.'
        assert_field 'Price paid for this device', with: amount
        assert_equal 150, unit.reload.unit_cost
        assert_not Event.exists?(action: 'equipment_purchase_cost_recorded', auditable: unit)
      end
      take_screenshot('icc-ordinary-unit-price-invalid-retry', html: true, full: true)
      page.current_window.resize_to(390, 900)
      take_screenshot('icc-ordinary-unit-price-invalid-retry-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 900)
      fill_in 'Price paid for this device', with: '$1,234.50'
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal BigDecimal('1234.50'), unit.reload.unit_cost
      assert_equal 1, Event.where(action: 'equipment_purchase_cost_recorded', auditable: unit).count
      assert_not Event.exists?(action: 'icc_financial_evidence_updated', auditable: unit)
      within('#financial-history') do
        assert_text @admin.full_name
        assert_text '$150.00 → $1,234.50'
      end
      take_screenshot('icc-ordinary-unit-price-corrected', html: true, full: true)
    end

    test 'a stale invoice edit leaves its staged PDF out of the reviewed saved values' do
      order, = icc_order_with_unit
      saved_document = order.financial_document.attachment
      visit edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{order.id}")
      context = find('[data-document-upload-context-value]')['data-document-upload-context-value']
      attach_file 'Invoice or timesheet (PDF)', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')
      assert_selector '[data-scan-state="pending"]'
      scan = DocumentScan.where(user: @admin, purpose: 'financial_evidence', form_context: context).sole
      scan.update!(status: :clean, completed_at: Time.current)
      assert_selector '[data-scan-state="clean"]', text: 'Ready:', wait: 20
      ::Icanconnect::FilingWriter.new(actor: @admin).update_evidence!(record: order, attributes: { vendor_invoice_number: 'CURRENT-INVOICE' }, lock_version: order.lock_version)

      fill_in 'Invoice or timesheet reference', with: 'STALE-INVOICE'
      click_button 'Save costs and documents'
      assert_selector '[role="alert"]', text: 'The saved values are shown below'
      assert_field 'Invoice or timesheet reference', with: 'CURRENT-INVOICE'
      assert_not_equal context, find('[data-document-upload-context-value]')['data-document-upload-context-value']
      assert page.driver.wait_for_network_idle(timeout: 5)
      assert_no_selector 'input[type="hidden"][name="finance[financial_document]"]', visible: :all
      assert_no_selector 'input[type="hidden"][name="finance[financial_document_signed_id]"]', visible: :all
      assert_link 'View saved document', href: document_attachment_path(saved_document)
      assert_nil scan.reload.dismissed_at
      assert_empty scan.blob.attachments
      take_screenshot('icc-stale-pdf-review-reset', html: true, full: true)

      fill_in 'Invoice or timesheet reference', with: 'REVIEWED-INVOICE'
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal saved_document.blob_id, order.reload.financial_document.blob_id
      assert_equal 'REVIEWED-INVOICE', order.vendor_invoice_number
      assert_empty scan.blob.attachments
      take_screenshot('icc-stale-pdf-after-review', html: true, full: true)
    end

    test 'empty filing period has no filing action' do
      visit admin_icanconnect_filing_prep_path
      assert_text 'No unclaimed expenses match these dates'
      assert_no_button 'Mark selected costs as filed'
      take_screenshot('icc-empty-filing', html: true, full: true)
    end

    test 'service bill preserves an invalid typed date and accepts the month first correction' do
      _order, unit = icc_order_with_unit
      visit new_admin_icanconnect_financial_record_path(application_id: unit.application_id)
      select 'Travel', from: 'Category'
      select "##{unit.id} — #{unit.product.name}", from: 'Device'
      fill_in 'Service date', with: '02/30/2026'
      fill_in 'Provider name', with: 'Travel provider'
      fill_in 'Amount billed', with: '25.50'
      fill_in 'Invoice number', with: 'TRAVEL-1'
      click_button 'Save bill and add documents'
      assert_selector '[role="alert"]', text: 'Service date'
      assert_field 'Service date', with: '02/30/2026'
      assert_field 'Provider name', with: 'Travel provider'
      assert_equal BigDecimal('25.50'), find_field('Amount billed').value.to_d
      assert_field 'Invoice number', with: 'TRAVEL-1'
      assert_equal 0, unit.application.application_service_expenses.count
      take_screenshot('icc-service-bill-invalid-date', html: true, full: true)

      fill_in 'Service date', with: Date.current.strftime('%m/%d/%Y')
      click_button 'Save bill and add documents'
      bill = unit.application.application_service_expenses.sole
      assert_current_path edit_admin_icanconnect_financial_record_path("ApplicationServiceExpense:#{bill.id}")
      assert_text "Costs and documents: Service bill ##{bill.id}"
      assert_equal Date.current, bill.service_date
      assert_equal BigDecimal('25.50'), bill.amount
      assert_equal 'Travel provider', bill.vendor_name
      take_screenshot('icc-service-bill-date-corrected', html: true, full: true)
    end

    test 'unfiled sibling receipt can be recorded while shared invoice price changes need a correction' do
      order, filed = icc_order_with_unit
      sibling = create(:equipment_item, application: filed.application, purchase_order: order, funding_source: 'icanconnect', unit_cost: 50,
                                        shipped_at: Date.current, tracking_number: 'SHARED-INVOICE-SIBLING')
      order.update!(invoice_total: 215)
      ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(filed)], period: 'Test period', external_reference: 'ICC-UNIT-FILED')
      visit edit_admin_icanconnect_financial_record_path("EquipmentItem:#{sibling.id}")
      assert_no_selector 'textarea[name="correction_reason"][required]'
      assert_no_selector 'input[name="correction_reference"][required]'
      fill_in 'Date received by the recipient', with: Date.current.strftime('%m/%d/%Y')
      fill_in 'Installation date', with: Date.current.strftime('%m/%d/%Y')
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal Date.current, sibling.reload.delivered_on
      assert_equal Date.current, sibling.installed_on
      take_screenshot('icc-shared-invoice-first-receipt', html: true, full: true)

      fill_in 'Price paid for this device', with: '51.00'
      click_button 'Save costs and documents'
      assert_selector '[role="alert"]'
      assert_equal BigDecimal('51'), find_field('Price paid for this device').value.to_d
      assert_field 'Date received by the recipient', with: Date.current.strftime('%m/%d/%Y')
      assert_equal 50, sibling.reload.unit_cost
      take_screenshot('icc-shared-invoice-cost-correction-needed', html: true, full: true)

      fill_in 'Correction reason', with: 'Supplier corrected the device price'
      fill_in 'External correction reference', with: 'ICC-SIBLING-CORRECTION'
      click_button 'Save costs and documents'
      assert_text 'Financial evidence saved.'
      assert_equal 51, sibling.reload.unit_cost
      assert Event.exists?(auditable: sibling, action: 'icc_filed_cost_corrected')
      assert filed.reload.icc_claimed?
      assert_not sibling.icc_claimed?
      assert order.reload.icc_financial_evidence_locked?
      take_screenshot('icc-shared-invoice-cost-corrected', html: true, full: true)
    end

    test 'a pending MAT voucher and iCanConnect purchase work on the same approved application' do
      FeatureFlag.enable!(:vouchers_enabled)
      application = create(:application, :completed, :with_id_proof, :with_residency_proof, :with_disability_certification,
                           user: create(:constituent, hearing_disability: true, vision_disability: true), program_disability_groups: ['deafblind'],
                           application_date: Date.current, income_proof_status: :not_reviewed)
      visit admin_applications_path(view: 'all', search: application.constituent_full_name)
      assert_no_text 'Updated income proof ready for review'
      visit admin_application_path(application, anchor: 'attachments-section')
      within '#proof_income_request_chooser' do
        click_button 'Send Secure Income Upload Link'
      end
      assert_selector '[data-testid="income-proof-secure-request-forms-panel"]', text: 'Email'
      request = application.secure_request_forms.find_by!(kind: :income_proof_resubmission)
      document = scanned_upload(fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
                                secure_form: request, slot: 'income_proof')
      result = Applications::SubmitProofResubmission.new(application: application, secure_request_form: request, file: document.signed_id).call
      assert result.success?, result.message
      assert_not application.reload.income_proof_required?
      assert_difference(-> { application.vouchers.count }, 1) { IssueInitialVoucherJob.perform_now(application.id, @admin.id) }
      visit admin_applications_path(view: 'review', filter: 'proofs_needing_review')
      assert_text application.constituent_full_name
      assert_text 'Updated income proof ready for review'
      take_screenshot('voucher-icc-proof-in-the-review-queue', html: true, full: true)

      visit admin_application_path(application, anchor: 'attachments-section')
      click_review_proof_and_wait('income')
      within '#incomeProofReviewModal' do
        accept_confirm { click_button 'Approve' }
      end
      assert_no_selector '#incomeProofReviewModal[open]'
      assert application.reload.icanconnect_eligible?
      assert_not application.income_proof_required?

      product = create(:product)
      click_link 'Edit equipment needs'
      select product.catalog_label, from: 'Catalog model'
      fill_in 'Reason for adjustment', with: 'iCanConnect device'
      click_button 'Save purchasing needs'
      assert_text 'Purchasing needs updated.'
      need = application.equipment_needs.sole
      visit new_admin_bid_group_path(need_ids: [need.id])
      assert_text 'Funding source: iCanConnect'
      fill_in 'Bid number', with: 'ICC-AND-VOUCHER-BID'
      take_screenshot('voucher-icc-bid-review', html: true, full: true)
      click_button 'Reserve selected products under this bid'
      assert_text 'Bid reserved.'
      click_link 'Enter PO details for this bid'
      fill_in 'New PO number', with: 'ICC-AND-VOUCHER-PO'
      click_button 'Save PO details'
      assert_text 'Award and unsent PO recorded.'
      order = PurchaseOrder.find_by!(number: 'ICC-AND-VOUCHER-PO')
      assert_equal 'icanconnect', order.equipment_items.sole.funding_source
      assert_equal application.id, order.equipment_items.sole.application_id
      assert application.reload.voucher_fulfillment?
      assert_equal 1, application.vouchers.count
    end

    test 'annual income update uses the existing application secure link and proof review queue' do
      mail_delivery = mock('income-update-mail-delivery')
      mail_delivery.stubs(:deliver_now).returns(true)
      mail_delivery.stubs(:deliver_later).returns(true)
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(mail_delivery)
      ApplicationNotificationsMailer.stubs(:proof_received).returns(mail_delivery)
      application = nil
      travel_to Date.current.prev_year.in_time_zone.noon do
        application = approved_deafblind_application
        icc_order_with_unit(application: application)
      end
      lifecycle = application.status_changes.order(:id).ids
      visit admin_application_path(application, anchor: 'attachments-section')
      assert_text 'Updated income proof is needed before adding iCanConnect equipment or services.'
      assert_text 'The application stays approved and MAT-funded work can continue.'
      take_screenshot('icc-income-update-existing-application', html: true, full: true)
      within '#proof_income_request_chooser' do
        assert_checked_field "proof_income_recipient_#{application.user_id}"
        click_button 'Send Secure Income Upload Link'
      end
      assert_selector '[data-testid="income-proof-secure-request-forms-panel"]', text: 'Email'
      form = application.secure_request_forms.find_by!(kind: :income_proof_resubmission)
      assert_equal application.user_id, form.recipient_id
      assert Notification.exists?(recipient: @admin, notifiable: application, action: 'income_proof_update_requested')
      take_screenshot('icc-income-update-requested', html: true, full: true)

      replacement = scanned_upload(fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
                                   secure_form: form, slot: 'income_proof')
      result = Applications::SubmitProofResubmission.new(application: application, secure_request_form: form, file: replacement.signed_id).call
      assert result.success?, result.message
      visit admin_applications_path(filter: 'proofs_needing_review')
      assert_text application.constituent_full_name
      assert_text 'Updated income proof ready for review'
      assert application.reload.status_approved?
      take_screenshot('icc-income-update-normal-review-queue', html: true, full: true)
      visit admin_application_path(application, anchor: 'attachments-section')
      assert_no_selector '#proof_income_request_chooser'
      click_review_proof_and_wait('income')
      within '#incomeProofReviewModal' do
        accept_confirm { click_button 'Approve' }
      end
      assert_no_selector '#incomeProofReviewModal[open]'
      assert_no_selector 'button[data-modal-id="incomeProofReviewModal"]'
      assert application.reload.income_proof_status_approved?
      assert application.status_approved?
      assert_equal lifecycle, application.status_changes.order(:id).ids
      assert_nothing_raised { ::Icanconnect::Funding.validate!(application, source: 'icanconnect') }
      take_screenshot('icc-income-update-approved-normally', html: true, full: true)
    end
  end
end
