# frozen_string_literal: true

require 'test_helper'

class VoucherVerificationServiceTest < ActiveSupport::TestCase
  WRONG_DOB = '10/09/1980'

  setup do
    @constituent = create(:constituent, date_of_birth: Date.new(1980, 9, 10))
    @voucher = create(:voucher, :active, application: create(:application, user: @constituent))
    @vendor = create(:vendor, :approved)
    @session = {}
    Policy.stubs(:get).with('voucher_verification_max_attempts').returns(3)
  end

  # Date.parse read 09/10/1980 as October 9 and counted the right answer as a mismatch.
  test 'a month-first date of birth verifies in every accepted spelling' do
    %w[09/10/1980 9/10/1980 09-10-1980 09101980 1980-09-10].each do |spelling|
      session = {}
      result = verify(spelling, session: session)

      assert result.success?, spelling
      assert_includes session[:verified_vouchers], @voucher.id
    end
  end

  test 'a wrong date uses an attempt' do
    result = verify(WRONG_DOB)

    assert_not result.success?
    assert_equal 'dob_verification_failed', result.message_key
    assert_equal 2, result.attempts_left
    assert_equal 1, result.attempt_number
    assert_equal 1, throttle.failed_attempts
  end

  # This used to call an undefined method and raise NoMethodError.
  test 'unreadable input is reported without using an attempt' do
    result = verify('9/10/80')

    assert_equal 'dob_verification_invalid_format', result.message_key
    assert_equal 3, result.attempts_left
    assert_equal 0, throttle.failed_attempts
    assert I18n.exists?("alerts.#{result.message_key}", :en)
  end

  test 'the last allowed mismatch locks this vendor out for the lockout period' do
    freeze_time do
      2.times { verify(WRONG_DOB) }
      result = verify(WRONG_DOB)

      assert result.locked_out?
      assert_equal 'dob_verification_too_many_attempts', result.message_key
      assert_equal 0, result.attempts_left
      assert_equal Time.current + VoucherVerificationThrottle::PERIOD, result.retry_at
    end
  end

  # Before this, the lock was never reached, and a correct guess always succeeded.
  test 'a correct date during the lockout is refused and uses no attempt' do
    3.times { verify(WRONG_DOB) }

    result = verify('09/10/1980')

    assert result.locked_out?
    assert_not result.success?
    assert_nil @session[:verified_vouchers]
    assert_equal 3, throttle.failed_attempts
  end

  test 'unreadable input during the lockout still reports the lockout' do
    3.times { verify(WRONG_DOB) }

    assert verify('garbage').locked_out?
  end

  test 'a new session does not reset the count' do
    3.times { verify(WRONG_DOB, session: {}) }

    assert verify('09/10/1980', session: {}).locked_out?
  end

  test 'the lockout belongs to one vendor, so another vendor can still verify' do
    3.times { verify(WRONG_DOB) }

    assert verify('09/10/1980', vendor: create(:vendor, :approved)).success?
  end

  test 'the lockout ends after the lockout period' do
    3.times { verify(WRONG_DOB) }

    travel VoucherVerificationThrottle::PERIOD + 1.second do
      result = verify('09/10/1980')

      assert result.success?
      assert_nil VoucherVerificationThrottle.find_by(voucher: @voucher, vendor: @vendor)
    end
  end

  test 'failures outside the window start a new count' do
    2.times { verify(WRONG_DOB) }

    travel VoucherVerificationThrottle::PERIOD + 1.second do
      result = verify(WRONG_DOB)

      assert_not result.locked_out?
      assert_equal 2, result.attempts_left
    end
  end

  test 'success clears earlier failures' do
    2.times { verify(WRONG_DOB) }

    result = verify('09/10/1980')

    assert result.success?
    assert_equal 3, result.attempt_number
    assert_nil VoucherVerificationThrottle.find_by(voucher: @voucher, vendor: @vendor)
  end

  # No answer can match, so counting attempts would only lock every vendor out.
  test 'an owner with no date of birth on file is reported without using an attempt' do
    @constituent.update_column(:date_of_birth, nil)

    result = verify('09/10/1980')

    assert result.unavailable?
    assert_not result.locked_out?
    assert_nil VoucherVerificationThrottle.find_by(voucher: @voucher, vendor: @vendor)
    assert I18n.exists?("alerts.#{result.message_key}", :en)
  end

  private

  def verify(dob, session: @session, vendor: @vendor)
    VoucherVerificationService.new(@voucher, dob, session, vendor: vendor).verify
  end

  def throttle
    VoucherVerificationThrottle.find_by!(voucher: @voucher, vendor: @vendor)
  end
end
