# frozen_string_literal: true

module Users
  # Service to send registration confirmations through mailer-managed routing.
  class RegistrationConfirmationService < BaseService
    def initialize(user:, request: nil)
      @user = user
      @request = request
      super()
    end

    def call
      send_confirmation
      success(nil, { method: preferred_communication_method.to_s })
    rescue StandardError => e
      failure("Failed to send registration confirmation: #{e.message}")
    end

                                                  private

    attr_reader :user, :request

    def preferred_communication_method
      user.effective_communication_preference.to_s
    end

    def send_confirmation
      ApplicationNotificationsMailer.registration_confirmation(user).deliver_later
    end
  end
end
