# frozen_string_literal: true

# Checks a constituent's date of birth before a vendor may redeem their voucher. Failed guesses are
# counted per voucher and vendor in VoucherVerificationThrottle; the session only carries the
# resulting grant.
class VoucherVerificationService
  attr_reader :voucher, :vendor, :submitted_dob_str, :session, :max_attempts

  def initialize(voucher, submitted_dob_str, session, vendor:)
    @voucher = voucher
    @vendor = vendor
    @submitted_dob_str = submitted_dob_str
    @session = session
    @max_attempts = (Policy.get('voucher_verification_max_attempts') || 3).to_i
  end

  def verify
    # No answer can ever match, so counting attempts would only lock vendors out for nothing.
    return no_dob_on_file_result if owner_date_of_birth.nil?

    VoucherVerificationThrottle.with_row_lock(voucher, vendor) do |throttle|
      # The lockout is checked first, so a correct guess during it is refused like any other.
      # Unreadable input is a typing problem, not a wrong answer, so it does not use an attempt.
      if throttle.locked?
        locked_result(throttle)
      elsif !valid_dob_format?
        remaining_result(throttle, 'dob_verification_invalid_format')
      elsif dobs_match?
        handle_successful_verification(throttle)
      else
        handle_failed_verification(throttle)
      end
    end
  end

  private

  def valid_dob_format?
    !parsed_dob.nil?
  end

  # Month first, like every date-of-birth field. Date.parse would read 09/10/1980 as October 9.
  def parsed_dob
    @parsed_dob ||= DateInputNormalizer.normalize(submitted_dob_str)
  end

  def owner_date_of_birth
    voucher.application.user&.date_of_birth
  end

  def dobs_match?
    parsed_dob == owner_date_of_birth
  end

  def no_dob_on_file_result
    VerificationResult.new(success: false, message_key: 'dob_verification_unavailable')
  end

  def handle_successful_verification(throttle)
    attempt_number = throttle.failed_attempts + 1
    throttle.destroy!
    verified_vouchers << voucher.id

    VerificationResult.new(success: true, message_key: 'dob_verification_success', attempt_number: attempt_number)
  end

  def handle_failed_verification(throttle)
    throttle.record_failure!(max_attempts)
    throttle.locked? ? locked_result(throttle) : remaining_result(throttle, 'dob_verification_failed')
  end

  def remaining_result(throttle, message_key)
    VerificationResult.new(
      success: false,
      message_key: message_key,
      attempts_left: [max_attempts - throttle.failed_attempts, 0].max,
      attempt_number: throttle.failed_attempts
    )
  end

  def locked_result(throttle)
    VerificationResult.new(
      success: false,
      message_key: 'dob_verification_too_many_attempts',
      attempts_left: 0,
      attempt_number: throttle.failed_attempts,
      retry_at: throttle.locked_until
    )
  end

  def verified_vouchers
    session[:verified_vouchers] ||= []
  end

  class VerificationResult
    attr_reader :success, :message_key, :attempts_left, :attempt_number, :retry_at

    def initialize(success:, message_key:, attempts_left: nil, attempt_number: nil, retry_at: nil)
      @success = success
      @message_key = message_key
      @attempts_left = attempts_left
      @attempt_number = attempt_number
      @retry_at = retry_at
    end

    def success?
      @success
    end

    def locked_out?
      retry_at.present?
    end

    # Retrying cannot help; the vendor needs the MAT Team.
    def unavailable?
      message_key == 'dob_verification_unavailable'
    end
  end
end
