# frozen_string_literal: true

# Measures one operation of ProofAttachmentService or DisabilityCertificationAttachmentService.
#
# It owns the result hash both services return ({ success:, error:, duration_ms: } plus what the operation adds),
# the elapsed time, and the single outcome log line. Each service keeps its own failure contract: whether the
# error is raised to the caller and what is audited.
module AttachmentOperation
  # @param subject [String] names the operation in its log line, such as "Proof income approved"
  # @param reraise [Boolean] raise the error to the caller after the outcome is logged
  # @param on_error [#call, nil] receives the error before the outcome is logged
  # @yield [Hash] the result. The operation sets :success and any extra keys.
  # @return [Hash] the result, unless the error is raised
  def self.measure(subject, reraise: false, on_error: nil)
    start_time = Time.current
    result = { success: false, error: nil, duration_ms: 0 }

    begin
      yield result
    rescue StandardError => e
      # A step after the attachment can fail once :success is set.
      result[:success] = false
      result[:error] = e
      on_error&.call(e)
      raise if reraise
    ensure
      result[:duration_ms] = ((Time.current - start_time) * 1000).round
      log_outcome(result, subject)
    end

    result
  end

  def self.log_outcome(result, subject)
    if result[:success]
      Rails.logger.info "#{subject} completed in #{result[:duration_ms]}ms"
    elsif Rails.env.test? && result[:error]&.message.to_s.match?(/mismatched digest/i)
      Rails.logger.debug { "[EXPECTED_TEST_ATTACHMENT] #{subject} failed in #{result[:duration_ms]}ms: #{result[:error].class.name}" }
    else
      Rails.logger.error "#{subject} failed in #{result[:duration_ms]}ms: #{result[:error]&.class&.name}"
    end
  rescue StandardError => e
    Rails.logger.error "Failed to log the #{subject} outcome: #{e.class.name}"
  end
  private_class_method :log_outcome
end
