# frozen_string_literal: true

class EmailVerificationJob < ApplicationJob
  queue_as :default

  def perform(medical_provider_email)
    unless medical_provider_email.email.match?(URI::MailTo::EMAIL_REGEXP)
      medical_provider_email.update(status: :failed)
      return
    end

    domain = medical_provider_email.email.split('@').last
    mx_records = nil
    Resolv::DNS.open do |dns|
      mx_records = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
    end

    if mx_records.empty?
      medical_provider_email.update(status: :failed)
      return
    end

    medical_provider_email.update(status: :verified)
  rescue StandardError => e
    Rails.logger.error "Email verification failed: #{e.class.name}"
    medical_provider_email.update(status: :failed)
  end
end
