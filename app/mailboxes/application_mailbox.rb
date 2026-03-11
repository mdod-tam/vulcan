# frozen_string_literal: true

class ApplicationMailbox < ActionMailbox::Base
  # Order matters: More specific routes first.

  # Use lambdas with direct string comparison
  routing lambda { |inbound_email|
    recipients = Array(inbound_email.mail.to).map { |address| address.to_s.downcase }
    result = recipients.any? { |address| address.match?(/\Adisability_cert(?:\+[^@]+)?@mdmat\.org\z/) }
    Rails.logger.info "MAILBOX ROUTING: disability_cert check = #{result} (to: #{inbound_email.mail.to})"
    result
  } => :medical_certification

  routing lambda { |inbound_email|
    result = (inbound_email.mail.to || []).include?('proof@example.com')
    Rails.logger.info "MAILBOX ROUTING: proof@example check = #{result} (to: #{inbound_email.mail.to})"
    result
  } => :proof_submission

  routing lambda { |inbound_email|
    result = (inbound_email.mail.to || []).include?(MatVulcan::InboundEmailConfig.inbound_email_address)
    Rails.logger.info "MAILBOX ROUTING: inbound address check = #{result} (to: #{inbound_email.mail.to}, expected: #{MatVulcan::InboundEmailConfig.inbound_email_address})"
    result
  } => :proof_submission

  # Default routing for unmatched emails
  routing(all: :default)
end
