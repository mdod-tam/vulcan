# frozen_string_literal: true

require 'test_helper'

class TextEmailLinkAccessibilityTest < ActiveSupport::TestCase
  URL_TOKEN_PATTERN = %r{
    https?://\S+ |
    %\{[a-z_]*(?:url|link)\} |
    %<[a-z_]*(?:url|link)>s |
    \{\{\s*[\w.]*(?:url|link)\s*\}\}
  }x

  AMBIGUOUS_LINK_TEXT_PATTERN = /
    \bclick\b |
    \bhere\b |
    link\s+below |
    below\s+to |
    haga\s+clic |
    hacer\s+clic |
    aqu[ií] |
    a\s+continuaci[oó]n
  /ix

  TEMPLATE_NAMES = %w[
    application_notifications_account_created
    application_notifications_proof_rejected
    application_notifications_proof_needs_review_reminder
    application_notifications_proof_requested
    application_notifications_provider_info_requested
    application_notifications_security_key_recovery_approved
    application_notifications_training_requested
    email_footer_text
    evaluator_mailer_new_evaluation_assigned
    medical_provider_certification_rejected
    medical_provider_request_certification
    user_mailer_email_verification
    user_mailer_password_reset
    vendor_notifications_w9_rejected
    vendor_notifications_w9_expired
    vendor_notifications_w9_expiring_soon
  ].freeze

  STAFF_ONLY_TEMPLATE_NAMES = %w[
    application_notifications_proof_needs_review_reminder
    application_notifications_training_requested
    evaluator_mailer_new_evaluation_assigned
    training_session_notifications_trainer_assigned
  ].freeze

  CONSTITUENT_FACING_TEMPLATE_NAMES = %w[
    application_notifications_account_created
    application_notifications_application_submitted
    application_notifications_income_threshold_exceeded
    application_notifications_max_rejections_reached
    application_notifications_medical_certification_not_provided
    application_notifications_proof_approved
    application_notifications_proof_received
    application_notifications_proof_rejected
    application_notifications_proof_requested
    application_notifications_provider_info_requested
    application_notifications_registration_confirmation
    application_notifications_security_key_recovery_approved
    evaluator_mailer_evaluation_submission_confirmation
    training_session_notifications_training_cancelled
    training_session_notifications_training_no_show
    training_session_notifications_training_rescheduled
    training_session_notifications_training_scheduled
    user_mailer_email_verification
    user_mailer_password_reset
    voucher_notifications_voucher_assigned
    voucher_notifications_voucher_expired
    voucher_notifications_voucher_expiring_soon
    voucher_notifications_voucher_redeemed
  ].freeze

  # Templates whose mailers resolve locale from the recipient (medical provider / vendor).
  # When adding new recipient-localized templates, register the name here and keep _es seeds.
  RECIPIENT_LOCALIZED_EMAIL_TEMPLATE_NAMES = %w[
    medical_provider_certification_approved
    medical_provider_certification_rejected
    medical_provider_request_certification
    vendor_notifications_w9_approved
    vendor_notifications_w9_expired
    vendor_notifications_w9_expiring_soon
    vendor_notifications_w9_rejected
  ].freeze

  # Locale keys used for plain-text email/SMS bodies that embed URLs via I18n.
  # When adding new locale-generated copy with URLs, register the dotted path here.
  LOCALE_SNIPPET_PATHS = [
    %w[application_notifications provider_info_requested email_instructions],
    %w[application_notifications proof_requested submission_options online],
    %w[application_notifications proof_rejected resubmission_options online],
    %w[vendor_notifications w9_rejected secure_upload_instructions],
    %w[vendor_notifications w9_rejected vendor_portal_instructions],
    %w[vendor_notifications w9_upload_requested body],
    %w[secure_provider_info_forms sms message],
    %w[secure_proof_forms sms message],
    %w[passwords account_access_sms message],
    %w[document_signing medical_certification_request body],
    %w[medical_provider_mailer certification_submission_instructions secure],
    %w[medical_provider_mailer certification_submission_instructions fax],
    %w[medical_provider_mailer certification_resubmission_instructions secure],
    %w[medical_provider_mailer certification_resubmission_instructions fax]
  ].freeze

  test 'stored text email template sources label URL-like lines with nearby purpose text' do
    TEMPLATE_NAMES.each do |template_name|
      seed_paths_for(template_name).each do |path|
        assert_accessible_url_lines(path.basename.to_s, template_bodies(path).join("\n"))
      end
    end
  end

  test 'staff-facing email templates are English only in seed data' do
    STAFF_ONLY_TEMPLATE_NAMES.each do |template_name|
      assert seed_path_for(template_name, 'en').exist?, "Expected English seed for #{template_name}"
      assert_not seed_path_for(template_name, 'es').exist?, "Unexpected Spanish seed for #{template_name}"
    end
  end

  test 'constituent-facing email templates include Spanish seed data' do
    CONSTITUENT_FACING_TEMPLATE_NAMES.each do |template_name|
      assert seed_path_for(template_name, 'en').exist?, "Expected English seed for #{template_name}"
      assert seed_path_for(template_name, 'es').exist?, "Expected Spanish seed for #{template_name}"
    end
  end

  test 'recipient-localized email templates include Spanish seed data' do
    RECIPIENT_LOCALIZED_EMAIL_TEMPLATE_NAMES.each do |template_name|
      assert seed_path_for(template_name, 'en').exist?, "Expected English seed for #{template_name}"
      assert seed_path_for(template_name, 'es').exist?, "Expected Spanish seed for #{template_name}"
    end
  end

  test 'locale-generated text email snippets label URL-like lines with nearby purpose text' do
    %w[en es].each do |locale|
      locale_data = locale_data_for(locale)

      LOCALE_SNIPPET_PATHS.each do |path|
        snippet = locale_data.dig(*path)

        assert snippet.present?, "Expected #{locale}.#{path.join('.')} to be present"
        assert_accessible_url_lines("#{locale}.#{path.join('.')}", snippet)
      end
    end
  end

  test 'email bodies with purpose-labelled URL lines remain plain text' do
    reset_url = 'https://example.test/password/edit?token=abc'
    proof_url = 'https://example.test/secure_proof_form?token=def'
    body = <<~TEXT
      Password reset link:
      #{reset_url}

      1. Secure proof upload link:
         #{proof_url}
    TEXT

    email = AccessibleLinkTestMailer.with(body: body).labelled_link

    assert_not email.multipart?
    assert_includes email.body.decoded, "Password reset link:\n#{reset_url}"
    assert_includes email.body.decoded, "Secure proof upload link:\n   #{proof_url}"
  end

  test 'email bodies without URLs remain text only' do
    email = AccessibleLinkTestMailer.with(body: 'No link in this message.').labelled_link

    assert_not email.multipart?
    assert_includes email.content_type, 'text/plain'
    assert_includes email.body.decoded, 'No link in this message.'
  end

  private

  def seed_paths_for(template_name)
    [
      seed_path_for(template_name, 'en'),
      seed_path_for(template_name, 'es')
    ].select(&:exist?)
  end

  def seed_path_for(template_name, locale)
    suffix = locale.to_s == 'en' ? '' : "_#{locale}"
    Rails.root.join('db/seeds/email_templates', "#{template_name}#{suffix}.rb")
  end

  def template_bodies(path)
    path.read.scan(/template\.body\s*=\s*<<~TEXT\n(.*?)^\s*TEXT/m).flatten.tap do |bodies|
      assert bodies.any?, "Expected #{path} to define at least one text template body"
    end
  end

  def locale_data_for(locale)
    YAML.safe_load_file(Rails.root.join('config/locales', "#{locale}.yml")).fetch(locale)
  end

  def assert_accessible_url_lines(source_name, text)
    lines = text.lines.map(&:rstrip)

    lines.each_with_index do |line, index|
      next unless line.match?(URL_TOKEN_PATTERN)

      assert_no_match AMBIGUOUS_LINK_TEXT_PATTERN, line,
                      "Ambiguous link text in #{source_name}: #{line.strip}"

      if bare_url_line?(line)
        label = previous_nonblank_line(lines, index)

        assert label.present?, "URL-like line in #{source_name} needs a purpose label: #{line.strip}"
        assert label.strip.end_with?(':'),
               "URL-like line in #{source_name} should follow a label ending with ':': #{line.strip}"
        assert_no_match AMBIGUOUS_LINK_TEXT_PATTERN, label,
                        "Ambiguous purpose label in #{source_name}: #{label.strip}"
      else
        text_before_url = line.split(URL_TOKEN_PATTERN).first.to_s

        assert text_before_url.include?(':'),
               "Inline URL-like token in #{source_name} needs a specific label before it: #{line.strip}"
      end
    end
  end

  def bare_url_line?(line)
    line.strip.match?(/\A(?:\d+\.\s*)?#{URL_TOKEN_PATTERN}\z/)
  end

  def previous_nonblank_line(lines, index)
    lines[0...index].rfind { |candidate| candidate.strip.present? }
  end
end
