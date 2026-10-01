# frozen_string_literal: true

class PostmarkEmailTracker
  def self.refresh(attempt)
    return unless attempt.server_id == EmailDelivery.postmark_server_id!

    claimed = false
    attempt.with_lock do
      if attempt.check_available?
        attempt.update!(last_checked_at: Time.current, check_count: attempt.check_count + 1)
        claimed = true
      end
    end
    return unless claimed

    token = Rails.application.credentials.postmark_api_token.presence || ENV.fetch('POSTMARK_API_TOKEN')
    client = Postmark::ApiClient.new(token)
    message = client.get_message(attempt.provider_message_id)
    EmailDelivery::Feedback.sdk(message, attempt).each do |fact|
      EmailDelivery::Feedback.apply(fact, server_id: attempt.server_id)
    end
    attempt.with_lock { attempt.update!(check_failed_at: nil) }
  rescue StandardError => e
    Rails.logger.warn("Postmark status check unavailable: #{e.class.name}")
    attempt.with_lock { attempt.update!(check_failed_at: Time.current) } if claimed
  end
end
