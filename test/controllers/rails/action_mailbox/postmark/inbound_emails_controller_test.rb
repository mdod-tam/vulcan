# frozen_string_literal: true

require 'test_helper'

module Rails
  module ActionMailbox
    module Postmark
      class InboundEmailsControllerTest < ActionDispatch::IntegrationTest
        test 'should accept inbound email with valid signature' do
          # Create a sample raw email content
          raw_email = <<~EMAIL
            From: sender@example.com
            To: proof@mdmat.org
            Subject: Test Inbound Email
            Message-ID: <test-message-id-123@example.com>
            Content-Type: text/plain

            This is a test email body
          EMAIL

          # Create a sample inbound email payload with raw email content
          payload = {
            RawEmail: raw_email
          }.to_json

          # Create a mock authenticator that returns true for authentication
          mock_authenticator = mock('authenticator')
          mock_authenticator.stubs(:authentic_request?).returns(true)

          # Make the controller use our mock authenticator
          Rails::ActionMailbox::Postmark::InboundEmailsController.any_instance.stubs(:authenticator).returns(mock_authenticator)

          # Post the payload to the inbound emails endpoint
          post rails_action_mailbox_postmark_inbound_emails_url, params: payload, headers: { 'Content-Type' => 'application/json' }

          # When successful, the controller returns a 200 OK status
          assert_response :success
        end

        test 'should reject inbound email with invalid signature' do
          # Create a sample raw email content
          raw_email = <<~EMAIL
            From: sender@example.com
            To: proof@mdmat.org
            Subject: Test Inbound Email
            Message-ID: <test-message-id-123@example.com>
            Content-Type: text/plain

            This is a test email body
          EMAIL

          # Create a sample inbound email payload with raw email content
          payload = {
            RawEmail: raw_email
          }.to_json

          # Create a mock authenticator that returns false for authentication
          mock_authenticator = mock('authenticator')
          mock_authenticator.expects(:authentic_request?).returns(false)

          # Make the controller use our mock authenticator
          Rails::ActionMailbox::Postmark::InboundEmailsController.any_instance.expects(:authenticator).returns(mock_authenticator)

          # Post the payload to the inbound emails endpoint
          post rails_action_mailbox_postmark_inbound_emails_url, params: payload, headers: { 'Content-Type' => 'application/json' }

          # When authentication fails, the controller returns a 401 Unauthorized status
          assert_response :unauthorized
        end
      end
    end
  end
end
