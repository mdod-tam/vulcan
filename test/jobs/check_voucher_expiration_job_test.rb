# frozen_string_literal: true

require 'test_helper'

# Runs the real processor and mail jobs. The expiration queries use the database clock,
# so issue dates are set relative to the current time rather than frozen Ruby time.
class CheckVoucherExpirationJobTest < ActiveJob::TestCase
  VALIDITY_MONTHS = 6

  setup do
    ensure_system_audit_actor!
    Policy.find_or_initialize_by(key: 'voucher_validity_period_months').update!(value: VALIDITY_MONTHS)
    load_seeded_email_templates('voucher_notifications_voucher_expiring_soon', 'voucher_notifications_voucher_expired')
    ActionMailer::Base.deliveries.clear
  end

  test 'warns a voucher inside the expiring-soon window once across repeated runs' do
    voucher = create_voucher(expires_in: 7.days)

    2.times { perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now } }

    assert voucher.reload.voucher_active?
    assert_equal 1, voucher.events.where(action: 'expiration_warning_sent').count
    assert_equal [[voucher_email(voucher)]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'expires a past-due voucher and sends exactly one expired notice' do
    voucher = create_voucher(expires_in: -1.day)

    2.times { perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now } }

    assert voucher.reload.voucher_expired?
    assert_equal 1, voucher.events.where(action: 'expired').count
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal [voucher_email(voucher)], ActionMailer::Base.deliveries.first.to
  end

  test 'a voucher due today is left for the expired run without a separate notice' do
    voucher = create_voucher(expires_in: 12.hours)

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert voucher.reload.voucher_active?
    assert_empty ActionMailer::Base.deliveries
  end

  test 'a disabled expired template still expires the voucher without mail' do
    EmailTemplate.where(name: 'voucher_notifications_voucher_expired').update_all(enabled: false)
    voucher = create_voucher(expires_in: -1.day)

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert voucher.reload.voucher_expired?
    assert_empty ActionMailer::Base.deliveries
  end

  private

  def create_voucher(expires_in:)
    application = create(:application, :completed)
    Voucher.create!(
      application: application,
      initial_value: 500,
      remaining_value: 500,
      status: :active,
      issued_at: VALIDITY_MONTHS.months.ago + expires_in
    )
  end

  def voucher_email(voucher)
    voucher.application.user.email
  end
end
