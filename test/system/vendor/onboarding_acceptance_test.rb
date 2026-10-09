# frozen_string_literal: true

require 'application_system_test_case'

class VendorOnboardingAcceptanceTest < ApplicationSystemTestCase
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
    sign_in_actor(@vendor)

    click_link 'Upload W9 on your profile'
    complete_required_profile_address
    fill_in 'Business name', with: 'Connected Vendor Updated'
    fill_in 'Website URL', with: 'ftp://example.test'
    attach_file 'Upload New W9', Rails.root.join('test/fixtures/files/sample_w9.pdf')
    check I18n.t('vendor_onboarding.terms.acceptance_label')
    click_button 'Save Changes'
    assert_text 'Website url must be a valid URL'
    assert_checked_field I18n.t('vendor_onboarding.terms.acceptance_label')
    assert_nil @vendor.reload.terms_accepted_at
    take_screenshot('vendor-profile-retained-upload-checked-terms-error', html: true, full: true)
    fill_in 'Website URL', with: 'https://example.test'
    click_button 'Save Changes'
    assert_text 'Your W9 is awaiting review'
    assert @vendor.reload.w9_status_pending_review?
    assert @vendor.vendor_pending?
    submitted_blob = @vendor.w9_form.blob
    take_screenshot('vendor-onboarding-awaiting-review', html: true, full: true)

    sign_in_actor(@admin)
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

    sign_in_actor(@vendor)
    assert_text 'W9 approved; vendor authorization is still pending'
    assert_no_link 'Process Voucher'
    take_screenshot('vendor-onboarding-awaiting-authorization', html: true, full: true)

    sign_in_actor(@admin)
    visit edit_admin_vendor_path(@vendor)
    select 'Approved', from: 'Vendor approval'
    click_button 'Update Vendor'
    assert @vendor.reload.vendor_approved?

    sign_in_actor(@vendor)
    open_redemption(@voucher, @constituent.date_of_birth)
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
    assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, page.evaluate_script('window.innerWidth')
    take_screenshot('vendor-redemption-dashboard-narrow', html: true, full: true)
    page.current_window.resize_to(1200, 800)

    open_redemption(@guardian_voucher, @dependent.date_of_birth)
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
      sign_in_actor(@admin)
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

      sign_in_actor(@vendor)
      click_link 'Invoices'
      click_link "Invoice #{invoice.invoice_number}"
      assert_text 'Paid'
      assert_text 'CONNECTED-CHECK'
      take_screenshot('vendor-connected-paid-invoice', html: true, full: true)
      [[purchase, 'CONNECTED-TRACKING-123', 'vendor-connected-purchase-tracking'],
       [guardian_purchase, 'CONNECTED-GUARDIAN-456', 'vendor-connected-guardian-purchase-tracking']].each do |order, tracking_number, screenshot_name|
        click_link 'Transactions'
        click_link "View purchase #{order.reference_number}"
        assert_text 'Waiting for shipping details'
        fill_in 'Tracking number', with: tracking_number
        click_button 'Save tracking number'
        assert_text 'Tracking number saved'
        assert_equal tracking_number, order.shipments.sole.tracking_number
        take_screenshot(screenshot_name, html: true, full: true)
      end

      [[@constituent, @application, 'CONNECTED-TRACKING-123', 'constituent'],
       [@guardian, @guardian_application, 'CONNECTED-GUARDIAN-456', 'guardian']].each do |viewer, application, tracking_number, viewer_role|
        sign_in_actor(viewer)
        visit constituent_portal_application_path(application)
        within('#orders-and-shipping') do
          assert_text 'Connected Vendor Updated'
          assert_text tracking_number
          assert_text '$50.00'
        end
        take_screenshot("vendor-connected-purchase-#{viewer_role}", html: true, full: true)
      end
    end
  end

  test 'production-style unpublished terms block new browser acceptance without blocking profile work' do
    sign_in_actor(@vendor)
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

  def open_redemption(voucher, date_of_birth)
    click_link 'Process a voucher'
    fill_in 'Voucher Code', with: voucher.code
    click_button 'Verify Voucher'
    assert_text 'Identity Verification'
    fill_in 'date_of_birth', with: date_of_birth.strftime('%m/%d/%Y')
    click_button 'Verify Identity'
    assert_text 'Voucher Redemption'
  end

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

  def sign_in_actor(actor)
    Capybara.reset_sessions!
    install_stimulus_error_reporting
    system_test_sign_in(actor)
  end
end
