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
      outcome = queue_confirmation
      data = { method: preferred_communication_method.to_s, delivery_outcome: outcome }
      return success(nil, data) if %i[queued deferred].include?(outcome)
      return failure(I18n.t('outbound_delivery.delivery_suppressed'), data.merge(delivery_suppressed: true)) if outcome == :suppressed

      failure('Registration confirmation could not be queued.', data)
    rescue StandardError => e
      failure("Failed to send registration confirmation: #{e.message}")
    end

    private

    attr_reader :user, :request

    def queue_confirmation
      mail = ApplicationNotificationsMailer.registration_confirmation(user)
      return EmailDelivery.deliver_later(mail) unless preferred_communication_method == 'letter'

      notice = NotificationService.create_and_deliver!(type: 'account_created', recipient: user, actor: user, notifiable: user,
                                                       deliver: false, channel: :letter)
      denial, context = EmailDelivery.issuance('ApplicationNotificationsMailer#registration_confirmation', channel: :letter, notification_id: notice.id)
      return denial.outcome if denial

      EmailDelivery.deliver_later(mail, context: context.merge('channel' => 'letter'))
    end

    def preferred_communication_method
      user.effective_communication_preference.to_s
    end
  end
end
