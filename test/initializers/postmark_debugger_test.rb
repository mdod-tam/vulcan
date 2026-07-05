# frozen_string_literal: true

require 'test_helper'

class PostmarkDebuggerTest < ActiveSupport::TestCase
  test 'redacts token-bearing Postmark payload fields before debug logging' do
    payload = {
      'TextBody' => 'Reset at https://example.com/password/edit?token=secret-reset-token',
      'HtmlBody' => '<a href="https://example.com/password/edit?token=secret-secondary-token">Reset</a>',
      'Metadata' => {
        'reset_url' => 'https://example.com/password/edit?token=secret-reset-token'
      },
      'Subject' => 'Account access token=secret-reset-token'
    }

    redacted = postmark_debugger.send(:redacted_postmark_payload, payload)

    assert_equal '[REDACTED_BODY]', redacted['TextBody']
    assert_equal '[REDACTED_BODY]', redacted['HtmlBody']
    assert_equal '[REDACTED]', redacted['Metadata']['reset_url']
    assert_includes redacted['Subject'], 'token=[REDACTED]'
    assert_not_includes redacted.to_json, 'secret-reset-token'
    assert_not_includes redacted.to_json, 'secret-secondary-token'
  end

  test 'redacts token-bearing Postmark provider exception text before logging' do
    client_class = Class.new do
      def handle_response(_response)
        raise StandardError, 'provider echoed https://example.com/password/edit?token=secret-reset-token'
      end
    end
    client_class.prepend(PostmarkDebugger)

    logs = capture_rails_logs do
      assert_raises(StandardError) do
        client_class.new.handle_response(:response)
      end
    end

    assert_includes logs, '[REDACTED_URL]'
    assert_not_includes logs, 'secret-reset-token'
    assert_not_includes logs, 'https://example.com/password/edit'
  end

  test 'redacts recipient contact fields and email addresses before debug logging' do
    payload = {
      'To' => 'Applicant <applicant@example.com>',
      'Cc' => 'caseworker@example.org',
      'Bcc' => ['auditor@example.net'],
      'From' => 'MAT <mat.program1@maryland.gov>',
      'ReplyTo' => 'support@example.gov',
      'Subject' => 'Account help for applicant@example.com',
      'Metadata' => {
        'recipient_email' => 'metadata-recipient@example.com',
        'contact' => '410-555-0198'
      }
    }

    redacted = postmark_debugger.send(:redacted_postmark_payload, payload)
    redacted_json = redacted.to_json

    assert_equal '[REDACTED_CONTACT]', redacted['To']
    assert_equal '[REDACTED_CONTACT]', redacted['Cc']
    assert_equal '[REDACTED_CONTACT]', redacted['Bcc']
    assert_equal '[REDACTED_CONTACT]', redacted['From']
    assert_equal '[REDACTED_CONTACT]', redacted['ReplyTo']
    assert_equal 'Account help for [REDACTED_EMAIL]', redacted['Subject']
    assert_equal '[REDACTED_CONTACT]', redacted['Metadata']['recipient_email']
    assert_equal '[REDACTED_CONTACT]', redacted['Metadata']['contact']
    assert_not_includes redacted_json, 'applicant@example.com'
    assert_not_includes redacted_json, 'caseworker@example.org'
    assert_not_includes redacted_json, 'auditor@example.net'
    assert_not_includes redacted_json, 'mat.program1@maryland.gov'
    assert_not_includes redacted_json, 'metadata-recipient@example.com'
    assert_not_includes redacted_json, '410-555-0198'
  end

  private

  def postmark_debugger
    Object.new.extend(PostmarkDebugger)
  end
end
