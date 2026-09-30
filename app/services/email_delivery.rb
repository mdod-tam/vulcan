# frozen_string_literal: true

# Shared delivery policy preserves captured control generations, with explicit
# catalog exceptions for required account access.
module EmailDelivery
  GLOBAL_CONTROL = 'email.global'
  ALL_CONTROL = 'communications.global'
  CHANNEL_CONTROLS = { 'email' => GLOBAL_CONTROL, 'letter' => 'communications.letters', 'sms' => 'communications.sms' }.freeze
  CONTROL_PREFIX = 'email.'
  CONTROL_PREFIXES = [CONTROL_PREFIX, 'communications.'].freeze
  CATEGORY_PREFIX = 'email.category.'
  CONTROL_NAMES = ([ALL_CONTROL] + CHANNEL_CONTROLS.values + Catalog::CATEGORIES.map { |category| "#{CATEGORY_PREFIX}#{category}" }).freeze

  def self.postmark_server_id!
    ENV['POSTMARK_SERVER_ID'].presence || raise(ConfigurationError.new('POSTMARK_SERVER_ID is required', reason: 'postmark_server_missing'))
  end

  def self.category_control(category)
    "#{CATEGORY_PREFIX}#{category}"
  end

  # A required control row is missing or cannot be read. Never a reason to send.
  class ConfigurationError < StandardError
    MESSAGE = 'Communication settings are missing or misconfigured'
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
    name.to_s.start_with?(*CONTROL_PREFIXES)
  end

  # For services that create a request only to email it: the check to make before creating the
  # request, rotating tokens, or changing sent state. Returns [denial, context]; denial is nil when
  # the email may go ahead, and context is the authorization to hand to deliver_now! later.
  def self.issuance(mail_action, params: {}, channel: 'email', notification_id: Current.notification_id)
    context = Policy.capture(mail_action: mail_action, params: params)
    context['notification_id'] = notification_id if notification_id
    decision = Policy.verify_delivery(mail_action, context, channel: channel)
    return [nil, context] if decision.allowed?

    Outcome.record_not_sent(decision, context: context.merge('channel' => channel), mail_action: mail_action)
    [decision, context]
  end

  # issuance, for a caller that sends through its own provider instead of a mailer.
  def self.issuance_denial(mail_action, params: {})
    issuance(mail_action, params: params).first.tap { |decision| decision&.raise_if_configuration_error! }
  end

  # :deferred means an enqueue intent awaiting commit; :queued means accepted by the adapter.
  # Refusal/error outcomes retain their classification, and the job records deferred failures.
  def self.deliver_later(delivery, context: nil)
    Current.denial_decision = nil
    deferred = ActiveRecord::Base.current_transaction.open?
    job = if context
            Current.set(context: context, queued: true) { delivery.deliver_later }
          else
            delivery.deliver_later
          end
    # A refused enqueue returns false, not nil, so safe navigation would not guard it.
    return deferred ? :deferred : :queued if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    Current.denial_decision&.outcome || :enqueue_failed
  end

  # deliver_now for a message that must be sent: a message stopped at the final check raises
  # DeliverySkipped, so the caller can handle the request it prepared.
  # Pass the context from issuance so the final check verifies the authorization the request was
  # prepared under, not the settings at the moment of sending. Retries keep the original request id.
  def self.deliver_now!(delivery, context: nil)
    Current.denial_decision = nil
    result =
      if context
        Current.set(context: context, queued: true) { delivery.deliver_now }
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

  # Providers and letter owners use the same refusal signal as required mail deliveries.
  def self.verify!(action, context:, channel:)
    decision = Policy.verify_delivery(action, context, channel: channel)
    return if decision.allowed?

    Outcome.record_not_sent(decision, context: context&.merge('channel' => channel), mail_action: action)
    decision.raise_if_configuration_error!
    raise ApplicationMailer::DeliverySkipped.new(reason: decision.reason)
  end
end
