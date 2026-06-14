# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  include SecureErrorSanitizer

  TEXT_URL_PATTERN = %r{(?:https?://|www\.)[^\s<>"']+}
  URL_ONLY_LINE_PATTERN = /\A\s*(?:\d+\.\s*)?(?<url>#{TEXT_URL_PATTERN})\s*\z/
  PURPOSE_LABEL_LINE_PATTERN = /\A\s*(?:\d+\.\s*)?(?<label>[^:\n]+):\s*\z/
  INLINE_PURPOSE_LINK_PATTERN = /(?<label>[^:\n]{2,80}?):\s*(?<url>#{TEXT_URL_PATTERN})/
  STAFF_TEMPLATE_LOCALE = 'en'

  class NoopDelivery
    attr_reader :channel, :reason

    def initialize(channel: nil, reason: nil)
      @channel = channel&.to_s
      @reason = reason&.to_s
    end

    def deliver_later = self
    def deliver_now = self
  end

  helper :mailer

  default(
    from: 'no_reply@mdmat.org',
    charset: 'UTF-8'
  )

  layout 'mailer'
  before_action :set_common_variables

  # Common email sender used by all mailers
  # Checks if template is enabled before sending and logs warnings if disabled
  def send_email(recipient_email, template, variables, mail_options = {})
    unless template.enabled?
      Rails.logger.warn("Email template '#{template.name}' is disabled. Skipping email to #{recipient_email}")
      return
    end

    variables = common_template_variables.merge(variables)
    rendered_subject, rendered_text_body = template.render(**variables)

    # Apply subject override if provided
    subject_override = mail_options.delete(:subject_override)
    rendered_subject = subject_override.call(rendered_subject) if subject_override.present?

    default_options = {
      to: recipient_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    }

    mail_with_accessible_text_body(default_options.merge(mail_options), rendered_text_body)
  end

  private

  def mail_with_accessible_text_body(mail_options, text_body)
    text_body = text_body.to_s

    return text_only_mail(mail_options, text_body) unless text_body.match?(TEXT_URL_PATTERN)

    mail(mail_options) do |format|
      format.text { render plain: text_body }
      format.html { render body: accessible_email_html_from_text(text_body), layout: false }
    end
  end

  def text_only_mail(mail_options, text_body)
    mail(mail_options) do |format|
      format.text { render plain: text_body }
    end
  end

  def audience_template_locale(recipient:)
    return staff_template_locale if staff_email_recipient?(recipient)

    resolve_template_locale(recipient: recipient)
  end

  def staff_template_locale
    STAFF_TEMPLATE_LOCALE
  end

  def staff_email_recipient?(recipient)
    return false unless recipient

    %i[admin? trainer? evaluator?].any? { |predicate| recipient.respond_to?(predicate) && recipient.public_send(predicate) }
  end

  def accessible_email_html_from_text(text_body)
    paragraphs = accessible_html_paragraphs(text_body)

    <<~HTML
      <!DOCTYPE html>
      <html>
        <body>
          #{paragraphs.join("\n      ")}
        </body>
      </html>
    HTML
  end

  def accessible_html_paragraphs(text_body)
    paragraphs = []
    current_lines = []

    accessible_html_lines(text_body).each do |line|
      if line.blank?
        flush_accessible_html_paragraph(paragraphs, current_lines)
      else
        current_lines << line
      end
    end

    flush_accessible_html_paragraph(paragraphs, current_lines)
    paragraphs
  end

  def accessible_html_lines(text_body)
    lines = text_body.to_s.lines.map(&:chomp)
    html_lines = []
    index = 0

    while index < lines.length
      line = lines[index]
      next_line = lines[index + 1]

      if purpose_label_line?(line) && url_only_line?(next_line)
        html_lines << accessible_html_link_line(line, next_line)
        index += 2
      else
        html_lines << accessible_html_inline_links(line)
        index += 1
      end
    end

    html_lines
  end

  def flush_accessible_html_paragraph(paragraphs, current_lines)
    return if current_lines.empty?

    paragraphs << "<p>#{current_lines.join('<br>')}</p>"
    current_lines.clear
  end

  def accessible_html_link_line(label_line, url_line)
    "#{ERB::Util.html_escape(list_marker(label_line))}#{accessible_html_link(url_from_line(url_line), link_label(label_line))}"
  end

  def accessible_html_inline_links(line)
    escaped_segments = []
    remaining = line.to_s

    while (match = remaining.match(INLINE_PURPOSE_LINK_PATTERN))
      escaped_segments << ERB::Util.html_escape(match.pre_match)
      escaped_segments << accessible_html_link(match[:url], link_label(match[:label]))
      remaining = match.post_match
    end

    escaped_segments << ERB::Util.html_escape(remaining)
    escaped_segments.join
  end

  def accessible_html_link(url, label)
    safe_url = ERB::Util.html_escape(link_href(url))
    safe_label = ERB::Util.html_escape(label.to_s)

    %(<a href="#{safe_url}">#{safe_label}</a>)
  end

  def link_href(url)
    url = url.to_s
    return "https://#{url}" if url.start_with?('www.')

    url
  end

  def purpose_label_line?(line)
    line.to_s.match?(PURPOSE_LABEL_LINE_PATTERN)
  end

  def url_only_line?(line)
    line.to_s.match?(URL_ONLY_LINE_PATTERN)
  end

  def url_from_line(line)
    line.to_s.match(URL_ONLY_LINE_PATTERN)[:url]
  end

  def list_marker(line)
    line.to_s.strip[/\A\d+\.\s*/].to_s
  end

  def link_label(line)
    line.to_s.strip.sub(/\A\d+\.\s*/, '').delete_suffix(':').strip
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

  def queue_letter_delivery(recipient:, template_name:, variables:, letter_type: nil, application: nil)
    print_recipient = letter_recipient_for(recipient)
    letter_variables = common_template_variables.merge(variables.respond_to?(:to_h) ? variables.to_h.deep_symbolize_keys : variables.dup)
    letter_variables[:application] = application if application.present?

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: print_recipient,
      variables: letter_variables,
      letter_type: letter_type
    ).queue_for_printing
  end

  def letter_recipient_for(recipient)
    return recipient unless recipient.respond_to?(:dependent?) && recipient.dependent?
    return recipient unless recipient.respond_to?(:guardian_for_contact) && recipient.guardian_for_contact.present?

    recipient.guardian_for_contact
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

  def interpolate_template_text(template_text, variables = {})
    rendered_text = template_text.to_s.dup
    variables.each do |key, value|
      rendered_text = rendered_text.gsub("%{#{key}}", value.to_s)
      rendered_text = rendered_text.gsub("%<#{key}>s", value.to_s)
    end
    rendered_text
  end

  def header_title_from_template_subject(template:, subject_variables: {}, fallback: '')
    return fallback.to_s if template.blank?

    rendered_subject = interpolate_template_text(template.subject, subject_variables).strip
    rendered_subject.presence || fallback.to_s
  rescue StandardError
    fallback.to_s
  end
end
