# frozen_string_literal: true

require 'test_helper'

module Admin
  class EmailTemplatesTest < ActiveSupport::TestCase
    MockViewContext = Struct.new(:sample_data_for_template) do
      def sample_data_for_template(_template_name)
        { 'name' => 'System Test User' }
      end
    end

    setup do
      # Ensure we start with clean database state
      DatabaseCleaner.clean if defined?(DatabaseCleaner)

      @admin = create(:admin)
      unique_id = SecureRandom.hex(4)
      html_name  = "test_template_html_#{unique_id}"
      text_name  = "test_template_text_#{unique_id}"

      # Register our test template configs BEFORE creating records so validations succeed
      original_templates = EmailTemplate::AVAILABLE_TEMPLATES
      new_templates = original_templates.merge(
        html_name => {
          description: 'An HTML template used for system testing.',
          required_vars: ['name'],
          optional_vars: []
        },
        text_name => {
          description: 'A Text template used for system testing.',
          required_vars: ['name'],
          optional_vars: []
        }
      )

      EmailTemplate.send(:remove_const, :AVAILABLE_TEMPLATES) if EmailTemplate.const_defined?(:AVAILABLE_TEMPLATES)
      EmailTemplate.const_set(:AVAILABLE_TEMPLATES, new_templates)

      # Create template records *after* constant is ready
      @template_html = create(:email_template, :html, name: html_name, subject: 'HTML Subject',
                                                      body: '<p>HTML Body %<name>s</p>')
      @template_text = create(:email_template, :text, name: text_name, subject: 'Text Subject', body: 'Text Body %<name>s')

      # Override the helper method completely for tests to avoid any expensive operations
      Admin::EmailTemplatesHelper.define_method(:sample_data_for_template) do |_template_name|
        { 'name' => 'System Test User' }
      end

      # Also patch the controller to use a fast mock for view_context
      Admin::EmailTemplatesController.any_instance.stubs(:view_context).returns(
        MockViewContext.new
      )
    end

    teardown do
      # Mocha stubs on any_instance are typically cleared automatically,
      # but explicitly unstubbing can prevent state leakage if tests run differently.
      # However, standard Mocha teardown should handle this. If issues persist, uncomment:
      # ApplicationController.any_instance.unstub(:sample_data_for_template)

      # Clear deliveries
      ActionMailer::Base.deliveries.clear
    end

    test 'sending a test email' do
      # Test that the mail delivery works without going through the UI to validate the core functionality

      sample_data = { 'name' => 'System Test User Text' }
      rendered_subject, rendered_body = @template_text.render(**sample_data)

      assert_emails 1 do
        AdminTestMailer.with(
          user: @admin,
          recipient_email: @admin.email,
          template_name: @template_text.name,
          subject: rendered_subject,
          body: rendered_body,
          format: @template_text.format
        ).test_email.deliver_now
      end

      last_email = ActionMailer::Base.deliveries.last
      assert_not_nil last_email, 'No email was delivered'
      # Verify subject includes the specific template name
      assert_equal "[TEST] Text Subject (Template: #{@template_text.name})", last_email.subject
      assert_equal [@admin.email], last_email.to

      # Verify body uses the stubbed data for the text template
      # Check the body content properly based on email structure
      email_body = if last_email.multipart? && last_email.text_part
                     last_email.text_part.body.to_s
                   else
                     last_email.body.to_s
                   end
      assert_match 'Text Body System Test User Text', email_body
    end

    test 'previewing a template with variables' do
      # Test direct rendering to verify variable substitution works
      sample_data = { 'name' => 'System Test User HTML' }
      _rendered_subject, rendered_body = @template_html.render(**sample_data)
      assert_match 'HTML Body System Test User HTML', rendered_body
    end
  end
end
