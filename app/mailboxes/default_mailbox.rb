# frozen_string_literal: true

class DefaultMailbox < ApplicationMailbox
  def process
    Rails.logger.info "DEFAULT MAILBOX PROCESSING: Email from #{mail.from&.first} to #{mail.to} with subject '#{mail.subject}'"
    Rails.logger.info "DEFAULT MAILBOX: This email didn't match any specific routing rules"

    # Log the email for debugging
    Rails.logger.debug { "Email details: #{mail.inspect}" }
  end
end
