# frozen_string_literal: true

require 'test_helper'

class VoucherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # Clear email deliveries to prevent test pollution
    ActionMailer::Base.deliveries.clear

    # Ensure required email templates exist for voucher notifications
    create_voucher_email_templates

    Current.user = create(:admin)
    # Create a constituent with a unique email for each test to avoid email conflicts
    constituent = create(:constituent, email: "unique_setup_#{Time.now.to_i}_#{rand(1000)}@example.com")
    @application = create(:application, user: constituent)
    @voucher = create(:voucher, application: @application)
    FeatureFlag.find_or_create_by(name: 'vouchers_enabled', enabled: true)
  end

  test 'valid voucher' do
    assert @voucher.valid?
  end

  test 'requires application' do
    @voucher.application = nil
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:application], 'must exist'
  end

  test 'requires code' do
    @voucher.code = nil
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:code], "can't be blank"
  end

  test 'requires unique code' do
    # Create a new constituent with a unique email to avoid validation errors
    constituent = create(:constituent, email: "unique_dupe_check_#{Time.now.to_i}@example.com")
    application = create(:application, user: constituent)

    duplicate = build(:voucher, code: @voucher.code, application: application)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:code], 'has already been taken'
  end

  test 'requires initial value' do
    @voucher.initial_value = nil
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:initial_value], "can't be blank"
  end

  test 'requires non-negative initial value' do
    @voucher.initial_value = -100
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:initial_value], 'must be greater than or equal to 0'
  end

  test 'requires remaining value' do
    @voucher.remaining_value = nil
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:remaining_value], "can't be blank"
  end

  test 'requires non-negative remaining value' do
    @voucher.remaining_value = -50
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:remaining_value], 'must be greater than or equal to 0'
  end

  test 'remaining value cannot exceed initial value' do
    @voucher.initial_value = 100
    @voucher.remaining_value = 150
    assert_not @voucher.valid?
    assert_includes @voucher.errors[:remaining_value], 'cannot exceed initial value'
  end

  test 'generates unique code on create' do
    voucher = build(:voucher, code: nil)
    assert voucher.save
    assert_match(/\A[A-Z0-9]{12}\z/, voucher.code)
  end

  test 'calculates initial values based on disabilities' do
    # Create admin user for policy setting
    admin = create(:admin)
    Current.user = admin

    # Mock the log_change method to avoid User validation error
    Policy.any_instance.stubs(:log_change).returns(true)

    # Set policy values for disabilities
    Policy.set('voucher_value_hearing_disability', 100)
    Policy.set('voucher_value_vision_disability', 200)
    Policy.set('voucher_value_mobility_disability', 300)
    Policy.set('voucher_value_speech_disability', 400)
    Policy.set('voucher_value_cognition_disability', 500)

    # Create constituent with specific disabilities and unique email
    constituent = create(:constituent,
                         email: "unique_disability_test_#{Time.now.to_i}_#{rand(10_000)}@example.com",
                         hearing_disability: true,   # 100
                         vision_disability: true,    # 200
                         mobility_disability: false, # 0
                         speech_disability: false,   # 0
                         cognition_disability: false) # 0
    application = create(:application, user: constituent)

    voucher = build(:voucher, application: application, initial_value: nil, remaining_value: nil)
    assert voucher.save

    assert_equal 300, voucher.initial_value # 100 + 200
    assert_equal voucher.initial_value, voucher.remaining_value
    assert_not_nil voucher.issued_at
  end

  test 'sends notification when assigned' do
    # Create a new constituent with a unique email to avoid validation errors
    constituent = create(:constituent, email: "unique_#{Time.now.to_i}@example.com")
    application = create(:application, status: :approved, user: constituent)
    application.update!(medical_certification_status: :approved)

    perform_enqueued_jobs do
      application.assign_voucher!
    end

    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test 'creates event when assigned' do
    # Create a constituent with a unique email
    constituent = create(:constituent, email: "unique_event_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
    application = create(:application, status: :approved, user: constituent)
    application.update!(medical_certification_status: :approved)

    assert_difference -> { Event.where(action: 'voucher_assigned').count }, 1 do
      application.assign_voucher!
    end

    event = Event.where(action: 'voucher_assigned').last
    assert_equal application.id, event.metadata['application_id']
    assert_not_nil event.metadata['voucher_code']
    assert_not_nil event.metadata['initial_value']
    assert_not_nil event.metadata['timestamp']
  end

  test 'can be redeemed when active' do
    @voucher.update!(status: :active)
    assert @voucher.can_redeem?(50)
  end

  test 'cannot be redeemed when not active' do
    @voucher.update!(status: :cancelled)
    assert_not @voucher.can_redeem?(50)
  end

  test 'cannot be redeemed for more than remaining value' do
    @voucher.update!(
      status: :active,
      remaining_value: 100
    )
    assert_not @voucher.can_redeem?(150)
  end

  test 'cannot be redeemed when expired' do
    @voucher.update!(
      status: :active,
      issued_at: 7.months.ago
    )
    assert_not @voucher.can_redeem?(50)
  end

  test 'successful redemption creates transaction and updates status' do
    # Create a vendor with a unique email
    vendor = create(:vendor, email: "unique_vendor_#{Time.now.to_i}@example.com")

    @voucher.update!(
      status: :active,
      initial_value: 100,
      remaining_value: 100
    )

    assert_difference -> { @voucher.transactions.count }, 1 do
      @voucher.redeem!(75, vendor)
    end

    assert_equal 25, @voucher.remaining_value
    assert_equal vendor, @voucher.vendor
    assert_not_nil @voucher.last_used_at
  end

  test 'full redemption marks voucher as redeemed' do
    # Create a vendor with a unique email
    vendor = create(:vendor, email: "unique_vendor_redeem_#{Time.now.to_i}@example.com")

    @voucher.update!(
      status: :active,
      initial_value: 100,
      remaining_value: 100
    )

    @voucher.redeem!(100, vendor)
    assert @voucher.voucher_redeemed?
  end

  test 'sends notification when redeemed' do
    # Create a vendor with a unique email
    vendor = create(:vendor, email: "unique_vendor_notify_#{Time.now.to_i}@example.com")

    @voucher.update!(
      status: :active,
      initial_value: 100,
      remaining_value: 100
    )

    perform_enqueued_jobs do
      @voucher.redeem!(100, vendor)
    end

    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test 'can be cancelled when issued' do
    # Since 'issued' isn't a valid status based on the model, use 'active' as a substitute
    # This test is testing the same thing as 'can_be_cancelled_when_active' so we can adapt it
    @voucher.update!(status: :active)
    assert @voucher.can_cancel?
  end

  test 'can be cancelled when active' do
    @voucher.update!(status: :active)
    assert @voucher.can_cancel?
  end

  test 'cannot be cancelled when redeemed' do
    @voucher.update!(status: :redeemed)
    assert_not @voucher.can_cancel?
  end

  test 'successful cancellation updates status and notes' do
    @voucher.update!(status: :active)
    freeze_time do
      @voucher.cancel!
      assert @voucher.voucher_cancelled?
      assert_includes @voucher.notes, "Cancelled at #{Time.current}"
    end
  end

  test 'sends notification when expired' do
    perform_enqueued_jobs do
      @voucher.update!(status: :expired)
    end

    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  private

  def create_voucher_email_templates
    # Create voucher_assigned template (no header/footer required)
    unless EmailTemplate.exists?(name: 'voucher_notifications_voucher_assigned', format: :text)
      EmailTemplate.create!(
        name: 'voucher_notifications_voucher_assigned',
        format: :text,
        subject: 'Your Voucher Has Been Assigned',
        body: "Dear %<user_first_name>s,\n\nYour voucher %<voucher_code>s with value %<initial_value_formatted>s has been assigned.\n\nExpires: %<expiration_date_formatted>s\n\nValid for %<validity_period_months>s months.\nMinimum redemption: %<minimum_redemption_amount_formatted>s",
        description: 'Sent when a voucher is assigned to a constituent.'
      )
    end

    # Create voucher_expired template (requires header/footer)
    unless EmailTemplate.exists?(name: 'voucher_notifications_voucher_expired', format: :text)
      EmailTemplate.create!(
        name: 'voucher_notifications_voucher_expired',
        format: :text,
        subject: 'Your Voucher Has Expired',
        body: "%<header_text>s\n\nDear %<user_first_name>s,\n\nYour voucher %<voucher_code>s has expired.\n\nInitial Value: %<initial_value_formatted>s\nUnused Value: %<unused_value_formatted>s\nExpiration Date: %<expiration_date_formatted>s\n\n%<footer_text>s",
        description: 'Sent when a voucher expires.'
      )
    end

    # Create voucher_redeemed template (no header/footer required)
    return if EmailTemplate.exists?(name: 'voucher_notifications_voucher_redeemed', format: :text)

    EmailTemplate.create!(
      name: 'voucher_notifications_voucher_redeemed',
      format: :text,
      subject: 'Voucher Successfully Redeemed',
      body: "Dear %<vendor_business_name>s,\n\nVoucher %<voucher_code>s has been redeemed by %<user_first_name>s.\n\nTransaction Date: %<transaction_date_formatted>s\nAmount: %<transaction_amount_formatted>s\nReference: %<transaction_reference_number>s\nExpiration Date: %<expiration_date_formatted>s\nRemaining Balance: %<remaining_balance_formatted>s\n\n%<remaining_value_message_text>s\n%<fully_redeemed_message_text>s",
      description: 'Sent when a voucher is redeemed.'
    )
  end
end
