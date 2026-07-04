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

  private

  def postmark_debugger
    Object.new.extend(PostmarkDebugger)
  end
end
