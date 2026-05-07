# frozen_string_literal: true

class SmsService
  def self.send_message(phone_number, message, sensitive: false, context: {})
    # Log the SMS attempt
    if sensitive
      Rails.logger.info("SMS delivery requested: #{safe_context(context).merge(phone: masked_phone(phone_number)).inspect}")
    else
      Rails.logger.info("SMS to #{phone_number}: #{message}")
    end

    # In test/development without Twilio credentials, just log and return success
    return true unless twilio_configured?

    # Send via Twilio in production with proper credentials
    begin
      client = Twilio::REST::Client.new(
        Rails.application.config.twilio[:account_sid],
        Rails.application.config.twilio[:auth_token]
      )

      client.messages.create(
        from: Rails.application.config.twilio[:sms_from_number],
        to: phone_number,
        body: message
      )

      if sensitive
        Rails.logger.info("SMS sent successfully via Twilio: #{safe_context(context).merge(phone: masked_phone(phone_number)).inspect}")
      else
        Rails.logger.info("SMS sent successfully to #{phone_number} via Twilio")
      end
      true
    rescue Twilio::REST::RestError => e
      Rails.logger.error("Twilio SMS delivery failed: #{e.message}")
      Rails.logger.error("Twilio error code: #{e.code}") if e.respond_to?(:code)
      raise
    end
  rescue StandardError => e
    Rails.logger.error("SMS delivery failed: #{e.message}")
    Rails.logger.error("SMS error backtrace: #{e.backtrace.first(5).join("\n")}")
    raise
  end

  def self.twilio_configured?
    config = Rails.application.config.twilio
    config[:account_sid].present? &&
      config[:auth_token].present? &&
      config[:sms_from_number].present?
  end

  def self.masked_phone(phone_number)
    digits = phone_number.to_s.gsub(/\D/, '')
    last_four = digits.last(4)
    return '[FILTERED]' if last_four.blank?

    "***-***-#{last_four}"
  end
  private_class_method :masked_phone

  def self.safe_context(context)
    (context || {}).slice(:secure_request_form_id, :application_id, :recipient_id, :recipient_channel)
  end
  private_class_method :safe_context
end
