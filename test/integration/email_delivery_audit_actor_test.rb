# frozen_string_literal: true

require 'test_helper'

# Suppression audit is reachable from public requests, so it must never create or promote an account.
class EmailDeliveryAuditActorTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).find_each do |user|
      user.update_columns(email: "displaced-#{SecureRandom.hex(4)}@example.test")
    end
    User.instance_variable_set(:@system_user, nil)
    load_seeded_email_templates('user_mailer_password_reset')
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin,
                                     operation_id: SecureRandom.uuid)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    User.instance_variable_set(:@system_user, nil)
    Current.reset
    EmailDelivery::Current.reset
  end

  test 'a public password reset while email is off does not promote a constituent at the system address' do
    post sign_up_path, params: { user: {
      email: PublicAuditActor::SYSTEM_AUDIT_EMAIL, password: 'password123', password_confirmation: 'password123',
      first_name: 'Synthetic', last_name: "Person#{SecureRandom.hex(4)}", date_of_birth: '1991-02-03',
      phone: nil, phone_type: 'contact_email', timezone: 'Eastern Time (US & Canada)', locale: 'en',
      hearing_disability: true
    } }
    constituent = User.find_by_email(PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    assert_equal 'Users::Constituent', constituent.type
    reset!

    post password_path, params: { contact: constituent.email }

    assert_redirected_to sign_in_path
    assert_empty ActionMailer::Base.deliveries
    assert_equal 'Users::Constituent', User.find(constituent.id).type
    assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
  end

  test 'the recurring invoice job does not promote a constituent at the system address' do
    post sign_up_path, params: { user: {
      email: PublicAuditActor::SYSTEM_AUDIT_EMAIL, password: 'password123', password_confirmation: 'password123',
      first_name: 'Synthetic', last_name: "Person#{SecureRandom.hex(4)}", date_of_birth: '1991-02-03',
      phone: nil, phone_type: 'contact_email', timezone: 'Eastern Time (US & Canada)', locale: 'en',
      hearing_disability: true
    } }
    constituent = User.find_by_email(PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    vendor = create(:vendor)
    create(:voucher_transaction, vendor: vendor, amount: 75, processed_at: 1.day.ago)

    GenerateVendorInvoicesJob.perform_now

    assert_equal 'Users::Constituent', User.find(constituent.id).type
    invoice = Invoice.find_by!(vendor: vendor)
    assert_equal 1, invoice.voucher_transactions.count
    assert_not invoice.events.exists?(action: 'generated')
  end

  test 'scheduled voucher expiry cannot promote a public constituent at the system address' do
    post sign_up_path, params: { user: {
      email: PublicAuditActor::SYSTEM_AUDIT_EMAIL, password: 'password123', password_confirmation: 'password123',
      first_name: 'Synthetic', last_name: "Expiry#{SecureRandom.hex(4)}", date_of_birth: '1991-02-03',
      phone: nil, phone_type: 'contact_email', timezone: 'Eastern Time (US & Canada)', locale: 'en',
      hearing_disability: true
    } }
    constituent = User.find_by!(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    assert_equal 'Users::Constituent', constituent.type
    reset!
    Current.reset
    voucher = overdue_voucher

    CheckVoucherExpirationJob.perform_now

    assert voucher.reload.voucher_expired?
    assert_equal 'Users::Constituent', User.find(constituent.id).type
    assert User.find(constituent.id).authenticate('password123')
    assert_empty voucher.events
    assert_empty ActionMailer::Base.deliveries
  end

  test 'scheduled expiry with no system account persists and reports the missing audit actor' do
    Current.reset
    voucher = overdue_voucher
    purposes = []
    subscriber = ->(*args) { purposes << args.last[:purpose] }

    ActiveSupport::Notifications.subscribed(subscriber, 'system_audit_actor_missing') do
      assert_no_difference('User.count') { CheckVoucherExpirationJob.perform_now }
    end

    assert voucher.reload.voucher_expired?
    assert_nil PublicAuditActor.system_audit_actor
    assert_empty voucher.events
    assert_includes purposes, 'voucher status change'
  end

  test 'a staff voucher transition retains its current actor' do
    voucher = overdue_voucher

    Current.user = @admin
    voucher.update!(status: :cancelled)

    assert_equal @admin.id, voucher.events.find_by!(action: 'status_changed_to_cancelled').user_id
    assert_nil User.find_by_email(PublicAuditActor::SYSTEM_AUDIT_EMAIL)
  end

  test 'with no system account the email is still blocked and no account is created' do
    user = create(:constituent)

    assert_no_difference('User.count') do
      post password_path, params: { contact: user.email }
    end

    assert_empty ActionMailer::Base.deliveries
    assert_nil User.find_by_email(PublicAuditActor::SYSTEM_AUDIT_EMAIL)
  end

  private

  def overdue_voucher
    Policy.find_or_initialize_by(key: 'voucher_validity_period_months').update!(value: 6)
    create(:voucher, application: create(:application, :completed), status: :active, issued_at: 6.months.ago - 1.day)
  end
end
