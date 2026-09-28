# frozen_string_literal: true

# Email delivery controls. An email may be sent only while every control captured for it
# is enabled and still at the generation it had when the email was requested.
module EmailDelivery
  GLOBAL_CONTROL = 'email.global'
  CONTROL_PREFIX = 'email.'
  CATEGORY_PREFIX = 'email.category.'
  CONTROL_NAMES = ([GLOBAL_CONTROL] + Catalog::CATEGORIES.map { |category| "#{CATEGORY_PREFIX}#{category}" }).freeze

  def self.category_control(category)
    "#{CATEGORY_PREFIX}#{category}"
  end

  # A required control row is missing or cannot be read. Never a reason to send.
  class ConfigurationError < StandardError
    MESSAGE = 'Email settings are missing or misconfigured'
    attr_reader :reason

    def initialize(message = MESSAGE, reason: nil)
      @reason = reason
      super(message)
    end
  end

  Decision = Data.define(:outcome, :reason) do
    def self.allowed = new(outcome: :allowed, reason: nil)
    def self.suppressed(reason) = new(outcome: :suppressed, reason: reason.to_s)
    def self.configuration_error(reason) = new(outcome: :configuration_error, reason: reason.to_s)

    def allowed? = outcome == :allowed
    def suppressed? = outcome == :suppressed
    def configuration_error? = outcome == :configuration_error

    def raise_if_configuration_error!
      raise ConfigurationError.new(reason: reason) if configuration_error?
    end
  end

  def self.control_name?(name)
    name.to_s.start_with?(CONTROL_PREFIX)
  end

  # For services that create a request only to email it: the check to make before creating the
  # request, rotating tokens, or changing sent state. Returns [denial, context]; denial is nil when
  # the email may go ahead, and context is the authorization to hand to deliver_now! later.
  def self.issuance(mail_action, params: {})
    context = Policy.capture(mail_action: mail_action, params: params)
    decision = Policy.verify_delivery(mail_action, context)
    return [nil, context] if decision.allowed?

    Outcome.record_not_sent(decision, context: context, mail_action: mail_action)
    [decision, context]
  end

  # issuance, for a caller that sends through its own provider instead of a mailer.
  def self.issuance_denial(mail_action, params: {})
    issuance(mail_action, params: params).first.tap { |decision| decision&.raise_if_configuration_error! }
  end

  # Returns :queued, :suppressed, :configuration_error, or :enqueue_failed. Policy refusals
  # retain their classification; queue failures are recorded by the job. deliver_later
  # itself returns false for both refusals, and a failed queue write raises nothing. Call it outside
  # a transaction: inside one the queue write waits for commit, so :queued is not yet known.
  def self.deliver_later(delivery)
    Current.denial_decision = nil
    job = delivery.deliver_later
    # A refused enqueue returns false, not nil, so safe navigation would not guard it.
    return :queued if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    Current.denial_decision&.outcome || :enqueue_failed
  end

  # deliver_now for a message that must be sent: a message stopped at the final check raises
  # DeliverySkipped, so the caller can handle the request it prepared.
  # Pass the context from issuance so the final check verifies the authorization the request was
  # prepared under, not the settings at the moment of sending. Each send gets its own request id.
  def self.deliver_now!(delivery, context: nil)
    Current.denial_decision = nil
    result =
      if context
        Current.set(context: context.merge('request_id' => SecureRandom.uuid), queued: true) { delivery.deliver_now }
      else
        delivery.deliver_now
      end
    if (decision = Current.denial_decision)
      decision.raise_if_configuration_error!
      raise ApplicationMailer::DeliverySkipped.new(reason: decision.reason)
    end
    raise 'Email delivery was not accepted' if result == false

    result
  end
end
