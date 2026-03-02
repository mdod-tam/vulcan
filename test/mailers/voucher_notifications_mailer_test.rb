# frozen_string_literal: true

require 'test_helper'

class VoucherNotificationsMailerTest < ActionMailer::TestCase
  setup do
    # 1. Initialize Test Data
    @application = create(:application)
    @user = @application.user
    @voucher = create(:voucher, application: @application, issued_at: 6.months.ago)
    @vendor = create(:vendor, :approved)
    @transaction = create(:voucher_transaction,
                          voucher: @voucher,
                          vendor: @vendor,
                          status: :transaction_completed,
                          amount: 100.00)

    # 2. Create Mocks for Main Templates
    assigned_template = mock('email_template_assigned')
    assigned_template.stubs(:render).returns(['Voucher assigned', "Text Assigned for voucher #{@voucher.code}"])

    expiring_soon_template = mock('email_template_expiring')
    expiring_soon_template.stubs(:render).returns(['Voucher expiring soon', "Text Your voucher will expire soon."])

    expired_template = mock('email_template_expired')
    expired_template.stubs(:render).returns(['Voucher expired', "Text Expired for voucher #{@voucher.code}"])

    redeemed_template = mock('email_template_redeemed')
    redeemed_template.stubs(:render).returns(['Voucher redeemed', "Text Redeemed for voucher #{@voucher.code}"])

    # 3. Create Mocks for Header & Footer (CRITICAL FIX)
    #    The mailer now calls these for every email, so we must stub them.
    header_template = mock('email_header_text')
    header_template.stubs(:render).returns(['Header Subject', 'Header Content'])

    footer_template = mock('email_footer_text')
    footer_template.stubs(:render).returns(['Footer Subject', 'Footer Content'])

    # 4. Register All Stubs
    #    We use specific .with() calls so the right mock is returned for the right name.
    
    # Headers & Footers
    EmailTemplate.stubs(:find_by!).with(name: 'email_header_text').returns(header_template)
    EmailTemplate.stubs(:find_by!).with(name: 'email_footer_text').returns(footer_template)

    # Main Templates
    EmailTemplate.stubs(:find_by!).with(name: 'voucher_notifications_voucher_assigned', format: :text).returns(assigned_template)
    EmailTemplate.stubs(:find_by!).with(name: 'voucher_notifications_voucher_expiring_soon', format: :text).returns(expiring_soon_template)
    EmailTemplate.stubs(:find_by!).with(name: 'voucher_notifications_voucher_expired', format: :text).returns(expired_template)
    EmailTemplate.stubs(:find_by!).with(name: 'voucher_notifications_voucher_redeemed', format: :text).returns(redeemed_template)

    # 5. Stub Policy
    Policy.stubs(:get).returns(nil)
    Policy.stubs(:get).with('voucher_validity_period_months').returns(12)
    Policy.stubs(:get).with('minimum_voucher_redemption_amount').returns(10)
    Policy.stubs(:get).with('organization_name').returns('My Org')
    Policy.stubs(:get).with('support_email').returns('support@example.com')
  end

  test 'voucher_assigned' do
    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_assigned.deliver_now

    assert_emails 1
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to
    assert_equal 'Voucher assigned', email.subject
    assert_includes email.body.to_s, "Text Assigned for voucher #{@voucher.code}"
  end

  test 'voucher_expiring_soon' do
    # Override the generic stub from setup with a more specific one for this test
    specific_template = mock('specific_expiring')
    # Use a generic regex match for the body to avoid fragile date math in assertions
    specific_template.stubs(:render).returns(['Voucher expiring soon', "Text Your voucher will expire in 11 days"])
    
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'voucher_notifications_voucher_expiring_soon', format: :text)
                 .returns(specific_template)

    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_expiring_soon.deliver_now

    assert_emails 1
    assert_equal 'Voucher expiring soon', email.subject
    assert_includes email.body.to_s, "Text Your voucher will expire in 11 days"
  end

  test 'voucher_expired' do
    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_expired.deliver_now

    assert_emails 1
    assert_equal 'Voucher expired', email.subject
    assert_includes email.body.to_s, "Text Expired for voucher #{@voucher.code}"
  end

  test 'voucher_redeemed' do
    # 1. Define specific text we want to check for
    redeemed_text = "Text Redeemed for voucher #{@voucher.code} at #{@vendor.business_name}"
    
    # 2. Create a specific mock for this test
    specific_redeemed_template = mock('specific_redeemed')
    specific_redeemed_template.stubs(:render).returns(['Voucher redeemed', redeemed_text])

    # 3. Update ONLY the redeemed template stub (Header/Footer stubs from setup remain active!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'voucher_notifications_voucher_redeemed', format: :text)
                 .returns(specific_redeemed_template)

    # 4. Perform Action
    email = VoucherNotificationsMailer.with(transaction: @transaction).voucher_redeemed.deliver_now

    # 5. Assertions
    assert_emails 1
    assert_equal 'Voucher redeemed', email.subject
    assert_includes email.body.to_s, redeemed_text
  end
end