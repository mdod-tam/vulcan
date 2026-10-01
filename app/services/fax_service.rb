# frozen_string_literal: true

# The installed Twilio SDK removed Programmable Fax. Keep explicit refusal at the legacy
# interface until a replacement provider is separately approved; never silently report success.
class FaxService
  class FaxError < StandardError; end
  UNAVAILABLE_MESSAGE = 'Fax delivery is unavailable. Use an enabled email or printed-letter workflow.'

  def send_fax(delivery_context: nil, **)
    EmailDelivery.verify!('FaxService#certification_rejected', context: delivery_context, channel: :fax)
    raise FaxError, UNAVAILABLE_MESSAGE
  end

  def send_pdf_fax(delivery_context: nil, **)
    send_fax(delivery_context: delivery_context)
  end
end
