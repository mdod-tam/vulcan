# frozen_string_literal: true

class EmailVerificationJob < ApplicationJob
  queue_as :default

  def perform(certifying_professional_email)
    unless certifying_professional_email.email.match?(URI::MailTo::EMAIL_REGEXP)
      certifying_professional_email.update(status: :failed)
      return
    end

    domain = certifying_professional_email.email.split('@').last
    mx_records = nil
    Resolv::DNS.open do |dns|
      mx_records = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
    end

    if mx_records.empty?
      certifying_professional_email.update(status: :failed)
      return
    end

    certifying_professional_email.update(status: :verified)
  rescue StandardError => e
    Rails.logger.error "Email verification failed: #{e.class.name}"
    certifying_professional_email.update(status: :failed)
  end
end
