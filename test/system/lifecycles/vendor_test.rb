# frozen_string_literal: true

require 'application_system_test_case'

class VendorLifecycleTest < ApplicationSystemTestCase
  setup do
    FeatureFlag.enable!(:vouchers_enabled)
    ensure_system_audit_actor!
    @admin = create(:admin)
    @vendor = create(:vendor, business_name: 'Connected Vendor')
    @constituent = create(:constituent, date_of_birth: Date.new(1990, 2, 3))
    @application = create(:application, user: @constituent, status: :in_progress)
    @voucher = create(:voucher, :active, application: @application, initial_value: 100, remaining_value: 100)
    @guardian = create(:constituent)
    @dependent = create(:constituent, date_of_birth: Date.new(1992, 4, 5))
    create(:guardian_relationship, guardian_user: @guardian, dependent_user: @dependent)
    @guardian_application = create(:application, user: @dependent, managing_guardian: @guardian, status: :in_progress)
    @guardian_voucher = create(:voucher, :active, application: @guardian_application, initial_value: 100, remaining_value: 100)
    @product = create(:product, name: 'Connected acceptance phone', price: 50)
    install_stimulus_error_reporting
  end

  test 'pending vendor completes onboarding redemption invoicing payment and later shipment visibility' do
    VendorTerms.stubs(:published?).returns(true)
    VendorTerms.stubs(:agreement).returns('Test-only approved vendor agreement for connected browser acceptance.')
    assert @vendor.vendor_pending?
    assert_not @vendor.w9_form.attached?
    assert_nil @vendor.terms_accepted_at
    assert_empty @vendor.voucher_transactions
    system_test_sign_in(@vendor, bypass_mfa_enrollment: true)

    click_link 'Upload W9 on your profile'
    complete_required_profile_address
    fill_in 'Business name', with: 'Connected Vendor Updated'
    fill_in 'Website URL', with: 'ftp://example.test'
    attach_cleared_document 'Upload New W9', Rails.root.join('test/fixtures/files/sample_w9.pdf')
    check I18n.t('vendor_onboarding.terms.acceptance_label')
    click_button 'Save Changes'
    assert_text 'Website url must be a valid URL'
    assert_checked_field I18n.t('vendor_onboarding.terms.acceptance_label')
    assert_nil @vendor.reload.terms_accepted_at
    fill_in 'Website URL', with: 'https://example.test'
    click_button 'Save Changes'
    assert_text 'Your W9 is awaiting review'
    assert @vendor.reload.w9_status_pending_review?
    assert @vendor.vendor_pending?
    submitted_blob = @vendor.w9_form.blob

    system_test_switch_user(@admin, bypass_mfa_enrollment: true)
    visit admin_vendor_path(@vendor)
    click_link 'Review W9'
    assert_field 'w9_review_reviewed_blob_id', with: submitted_blob.id.to_s, type: 'hidden'
    click_button 'Load PDF Preview'
    assert_selector '[data-pdf-loader-target="container"] iframe[src]'
    click_button 'Approve'
    assert_text 'W9 review completed successfully'
    assert @vendor.reload.w9_status_approved?
    assert @vendor.vendor_pending?, 'document approval must not authorize the vendor account'
    assert_equal submitted_blob.id, @vendor.w9_reviews.sole.reviewed_blob_id

    system_test_switch_user(@vendor, bypass_mfa_enrollment: true)
    assert_text 'W9 approved; vendor authorization is still pending'
    assert_no_link 'Process Voucher'

    system_test_switch_user(@admin, bypass_mfa_enrollment: true)
    visit edit_admin_vendor_path(@vendor)
    select 'Approved', from: 'Vendor approval'
    click_button 'Update Vendor'
    assert @vendor.reload.vendor_approved?

    system_test_switch_user(@vendor, bypass_mfa_enrollment: true)
    assert_selector 'h2#monthly-totals-heading'
    assert_selector "table#monthly-totals-table[aria-labelledby='monthly-totals-heading']"
    assert_selector 'table#monthly-totals-table caption.sr-only'
    assert_selector '#chart-description.sr-only'
    assert_selector "button[data-chart-toggle-target='button']"
    assert_selector '#monthly-totals-chart', visible: :all
    accepted_at = @vendor.terms_accepted_at
    tax_id = @vendor.business_tax_id
    phone = @vendor.phone
    visit edit_vendor_portal_profile_path
    assert_field 'users_vendor_business_tax_id', with: ''
    assert_no_field 'users_vendor_terms_accepted'
    assert_no_field 'Phone'
    assert_link I18n.t('contact_changes.title'), href: new_contact_change_path
    fill_in 'Website URL', with: 'https://example.test/contact'
    click_button 'Save Changes'
    assert_text 'Profile updated successfully'
    assert_current_path vendor_portal_dashboard_path
    assert_equal accepted_at, @vendor.reload.terms_accepted_at
    assert_equal tax_id, @vendor.business_tax_id
    assert_equal phone, @vendor.phone
    assert_equal 'https://example.test/contact', @vendor.website_url
    click_link 'Process a voucher'
    open_voucher_redemption(@voucher, date_of_birth: @constituent.date_of_birth)
    assert_button 'Process Redemption', disabled: true
    page.current_window.resize_to(390, 844)
    select_product_by_keyboard
    assert_checked_field "product_#{@product.id}"
    assert_button 'Process Redemption', disabled: false
    fill_in 'Redemption Amount', with: '150.00'
    click_button 'Process Redemption'
    assert_text 'Cannot redeem more than the available amount'
    assert_field 'Redemption Amount', with: '150.00'
    assert_checked_field "product_#{@product.id}"
    retry_reference = find('input[name="submission_id"]', visible: :all).value
    assert_empty @vendor.voucher_transactions
    assert_equal 100, @voucher.reload.remaining_value
    take_screenshot('vendor-redemption-correctable-error-narrow', html: true, full: true)

    uncheck "product_#{@product.id}"
    assert_button 'Process Redemption', disabled: true
    select_product_by_keyboard
    fill_in 'Redemption Amount', with: '50.00'
    assert_equal retry_reference, find('input[name="submission_id"]', visible: :all).value
    find_field('Redemption Amount').send_keys(:enter)
    assert_text 'Voucher successfully processed'
    purchase = @vendor.voucher_transactions.sole
    assert_equal 50, purchase.amount
    assert_equal 50, @voucher.reload.remaining_value
    assert_equal [@product.id], purchase.products.pluck(:id)
    assert_empty purchase.shipments
    assert_no_horizontal_overflow
    page.current_window.resize_to(1200, 800)

    click_link 'Process a voucher'
    open_voucher_redemption(@guardian_voucher, date_of_birth: @dependent.date_of_birth)
    assert_button 'Process Redemption', disabled: true
    check "product_#{@product.id}"
    fill_in 'Redemption Amount', with: '50.00'
    click_button 'Process Redemption'
    assert_text 'Voucher successfully processed'
    guardian_purchase = @vendor.voucher_transactions.find_by!(voucher: @guardian_voucher)
    assert_equal 2, @vendor.voucher_transactions.count
    assert_equal 50, guardian_purchase.amount
    assert_equal 50, @guardian_voucher.reload.remaining_value
    assert_equal [@product.id], guardian_purchase.products.pluck(:id)
    assert_empty guardian_purchase.shipments

    # Invoice runs cover redemptions before the run day. Advance time through that boundary.
    travel 1.day do
      system_test_switch_user(@admin, bypass_mfa_enrollment: true)
      visit admin_invoices_path
      within('section', text: 'Not yet invoiced') do
        assert_text 'Connected Vendor Updated'
        assert_text '$100.00 in 2 voucher redemptions'
        click_button 'Invoice now'
      end
      invoice = @vendor.invoices.sole
      assert_equal invoice.id, purchase.reload.invoice_id
      assert_equal invoice.id, guardian_purchase.reload.invoice_id
      assert_equal 100, invoice.total_amount
      visit admin_invoice_path(invoice)
      click_button 'Approve invoice'
      assert_text 'Invoice approved.'
      fill_in 'Payment date', with: Date.current.strftime('%m/%d/%Y')
      select 'Check', from: 'Payment method'
      fill_in 'GAD invoice reference', with: 'CONNECTED-GAD'
      fill_in 'Check number (checks)', with: 'CONNECTED-CHECK'
      click_button 'Record payment'
      assert_text 'Payment recorded.'
      assert invoice.reload.status_invoice_paid?

      system_test_switch_user(@vendor, bypass_mfa_enrollment: true)
      click_link 'Invoices'
      click_link "Invoice #{invoice.invoice_number}"
      assert_text 'Paid'
      assert_text 'CONNECTED-CHECK'
      take_screenshot('vendor-connected-paid-invoice', html: true, full: true)
      [[purchase, 'CONNECTED-TRACKING-123'],
       [guardian_purchase, 'CONNECTED-GUARDIAN-456']].each do |order, tracking_number|
        click_link 'Transactions'
        click_link "View purchase #{order.reference_number}"
        assert_text 'Waiting for shipping details'
        fill_in 'Tracking number', with: tracking_number
        click_button 'Save tracking number'
        assert_text 'Tracking number saved'
        assert_equal tracking_number, order.shipments.sole.tracking_number
      end

      [[@constituent, @application, 'CONNECTED-TRACKING-123'],
       [@guardian, @guardian_application, 'CONNECTED-GUARDIAN-456']].each do |viewer, application, tracking_number|
        system_test_switch_user(viewer)
        visit constituent_portal_application_path(application)
        within('#orders-and-shipping') do
          assert_text 'Connected Vendor Updated'
          assert_text tracking_number
          assert_text '$50.00'
        end
      end
      take_screenshot('vendor-lifecycle-guardian-fulfillment', html: true, full: true)
    end
  end

  test 'production-style unpublished terms block new browser acceptance without blocking profile work' do
    system_test_sign_in(@vendor, bypass_mfa_enrollment: true)
    click_link 'Upload W9 on your profile'
    assert_text I18n.t('vendor_onboarding.terms.unavailable')
    assert_no_field 'users_vendor_terms_accepted'
    complete_required_profile_address
    fill_in 'Business name', with: 'Profile while terms unavailable'
    click_button 'Save Changes'
    assert_text 'Profile updated successfully'
    assert_equal 'Profile while terms unavailable', @vendor.reload.business_name
    assert_nil @vendor.terms_accepted_at
    click_link 'Upload W9 on your profile'
    click_link I18n.t('vendor_onboarding.terms.review')
    assert_text I18n.t('vendor_onboarding.terms.unavailable')
    take_screenshot('vendor-terms-unpublished', html: true, full: true)
  end

  private

  def select_product_by_keyboard
    # Cuprite Node#send_keys clicks a checkbox before typing, which would toggle it twice.
    find_field('Redemption Amount').send_keys(:tab)
    all('input.product-checkbox').size.times do
      break if page.has_selector?("#product_#{@product.id}:focus", wait: 0)

      page.driver.browser.keyboard.type(:tab)
    end
    assert_selector "#product_#{@product.id}:focus"
    page.driver.browser.keyboard.type(:space)
  end

  def complete_required_profile_address
    fill_in 'Address Line 1', with: '42 Connected Street'
    fill_in 'City', with: 'Baltimore'
    fill_in 'State', with: 'MD'
    fill_in 'Zip Code', with: '21201'
  end
end
