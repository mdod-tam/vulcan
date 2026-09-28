# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  include SecureErrorSanitizer

  class NoopDelivery
    attr_reader :channel, :reason

    def initialize(channel: nil, reason: nil)
      @channel = channel&.to_s
      @reason = reason&.to_s
    end

    def deliver_later = self
    def deliver_now = self
  end

  # Raised when a delivery that carries a secure link is intentionally not sent (a disabled
  # template or an email control), so the issuing service revokes the unsent link and records
  # a suppression rather than a failure.
  class DeliverySkipped < StandardError
    attr_reader :reason

    def initialize(message = nil, reason: nil)
      @reason = reason.to_s.presence || 'suppressed'
      super(message || "Email delivery suppressed: #{@reason}")
    end
  end

  helper :mailer

  default(
    from: 'no_reply@mdmat.org',
    charset: 'UTF-8'
  )

  layout 'mailer'
  before_action :set_common_variables

  self.delivery_job = EmailDelivery::MailDeliveryJob

  # Last check before handoff, for queued and immediate deliveries alike.
  before_deliver :enforce_email_delivery_controls

  private

  # Pass required_delivery: true in mail_options when the email carries a secure link.
  def send_email(recipient_email, template, variables, mail_options = {})
    required_delivery = mail_options.delete(:required_delivery)
    unless template.enabled?
      Rails.logger.warn("Email template '#{template.name}' is disabled. Skipping email to #{recipient_email}")
      # No message is built, so the final check never runs; record the suppression here.
      EmailDelivery::Outcome.record_not_sent(EmailDelivery::Decision.suppressed(:template_disabled),
                                             context: EmailDelivery::Current.context,
                                             mail_action: "#{self.class.name}##{action_name}")
      raise DeliverySkipped.new("Email template '#{template.name}' is disabled", reason: 'template_disabled') if required_delivery

      return
    end

    variables = common_template_variables.merge(variables)
    rendered_subject, rendered_text_body = template.render(**variables)

    subject_override = mail_options.delete(:subject_override)
    rendered_subject = subject_override.call(rendered_subject) if subject_override.present?

    default_options = {
      to: recipient_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    }

    mail_with_text_body(default_options.merge(mail_options), rendered_text_body)
  end

  # A letter route never calls mail, so it has nothing to stop here.
  def enforce_email_delivery_controls
    return unless @_mail_was_called

    mail_action = "#{self.class.name}##{action_name}"
    context = if EmailDelivery::Current.queued
                EmailDelivery::Current.context
              else
                EmailDelivery::Policy.capture(mail_action: mail_action, params: params || {})
              end
    decision = EmailDelivery::Policy.verify_delivery(mail_action, context)
    return if decision.allowed?

    EmailDelivery::Outcome.record_not_sent(decision, context: context, mail_action: mail_action)
    throw :abort
  end

  def mail_with_text_body(mail_options, text_body)
    mail(mail_options) do |format|
      format.text { render plain: text_body.to_s }
    end
  end

  def noop_delivery(channel: nil, reason: nil)
    NoopDelivery.new(channel: channel, reason: reason)
  end

  def noop_letter_delivery(reason: 'preference')
    noop_delivery(channel: :letter, reason: reason)
  end

  def prefers_letter_delivery?(recipient, override: nil)
    return override.to_s == 'letter' if override.present?

    preference =
      if recipient.respond_to?(:effective_communication_preference)
        recipient.effective_communication_preference
      elsif recipient.respond_to?(:communication_preference)
        recipient.communication_preference
      end

    preference.to_s == 'letter'
  end

  def recipient_email_for(recipient)
    return recipient.effective_email if recipient.respond_to?(:effective_email) && recipient.effective_email.present?
    return recipient.email if recipient.respond_to?(:email)

    nil
  end

  # Secure requests pass the resolver-selected print_recipient. Other callers retain the dependent-to-guardian fallback.
  def queue_letter_delivery(recipient:, template_name:, variables:, letter_type: nil, application: nil, print_recipient: nil)
    print_recipient ||= letter_recipient_for(recipient)
    letter_variables = common_template_variables.merge(variables.respond_to?(:to_h) ? variables.to_h.deep_symbolize_keys : variables.dup)
    letter_variables[:application] = application if application.present?

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: print_recipient,
      variables: letter_variables,
      letter_type: letter_type
    ).queue_for_printing
  end

  # Queues a printed letter when the recipient prefers mail. Returns true when the letter route
  # handles the message, so the caller sends no email.
  def queue_letter_if_preferred(recipient, template_name, variables, application: nil)
    return false unless prefers_letter_delivery?(recipient)

    queue_letter_delivery(recipient: recipient, template_name: template_name, variables: variables, application: application)
    true
  end

  def letter_recipient_for(recipient)
    return recipient unless recipient.respond_to?(:dependent?) && recipient.dependent?
    return recipient unless recipient.respond_to?(:guardian_for_contact) && recipient.guardian_for_contact.present?

    recipient.guardian_for_contact
  end

  # The form owns secure-request language. Historical ownerless forms use the
  # form's explicit recipient fallback rather than inferring an address owner.
  def secure_request_locale(secure_request_form, recipient)
    return secure_request_form.delivery_locale if secure_request_form.present?

    resolve_template_locale(recipient: recipient)
  end

  def resolve_template_locale(recipient: nil)
    recipient_locale = if recipient.respond_to?(:effective_locale)
                         normalize_locale(recipient.effective_locale)
                       elsif recipient.respond_to?(:locale)
                         normalize_locale(recipient.locale)
                       end
    default_locale = normalize_locale(I18n.default_locale) || 'en'

    recipient_locale || default_locale
  end

  def find_text_template(template_name, locale: nil)
    resolved_locale = normalize_locale(locale) || resolve_template_locale
    EmailTemplate.find_by!(name: template_name, format: :text, locale: resolved_locale)
  rescue ActiveRecord::RecordNotFound
    fallback_locale = I18n.default_locale.to_s
    raise if resolved_locale == fallback_locale

    Rails.logger.debug { "No #{resolved_locale} template for #{template_name}, falling back to #{fallback_locale}" }
    EmailTemplate.find_by!(name: template_name, format: :text, locale: fallback_locale)
  end

  def set_common_variables
    @current_year = Time.current.year
    @organization_name = 'Maryland Accessible Telecommunications Program'
    @organization_email = 'no_reply@mdmat.org'
    @organization_website = ProgramContact.website_url
  end

  def common_template_variables
    {
      office_address: ProgramContact.office_address,
      program_website_url: ProgramContact.website_url
    }
  end

  def normalize_locale(locale)
    candidate = locale.to_s.strip
    return nil if candidate.empty?

    candidate.tr('_', '-').split('-').first.downcase
  end

  def header_title_from_template_subject(template:, subject_variables: {}, fallback: '')
    return fallback.to_s if template.blank?

    rendered_subject = template.render_subject(**subject_variables).to_s.strip
    rendered_subject.presence || fallback.to_s
  rescue StandardError
    fallback.to_s
  end

  def log_mail_error(error, user, template_name, variables)
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: sanitize_secure_error_message(error.message),
        error_class: error.class.name,
        template_name: template_name,
        variables: sanitized_mail_variables(variables),
        backtrace: sanitize_secure_value(error.backtrace&.first(5))
      }
    )
  end

  def sanitized_mail_variables(variables)
    redact_sensitive_mail_value(variables.to_h.deep_dup)
  end

  def redact_sensitive_mail_value(value, key = nil)
    sanitize_secure_value(value, key)
  end
end
