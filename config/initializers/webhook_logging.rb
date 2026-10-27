# frozen_string_literal: true

ActiveSupport::Notifications.subscribe 'webhook_received' do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)

  Rails.logger.info(
    "Webhook received: #{event.payload[:controller]}##{event.payload[:action]} " \
    "Type=#{event.payload[:type]} " \
    "Duration=#{event.duration.round(2)}ms"
  )
end
