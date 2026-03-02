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

      # Create template records
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
      rendered_subject, rendered_body = @template_text.render(**sample_data.symbolize_keys)

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

    test 'validate_variables_in_body rejects unauthorized variables' do
      # Test that adding an unauthorized variable causes validation to fail
      @template_text.body = 'Hello %<name>s, here is an unauthorized variable: %<unauthorized_var>s'

      assert_not @template_text.valid?, 'Template should be invalid with unauthorized variables'
      assert @template_text.errors[:body].any?, 'Should have body errors'
      assert_includes @template_text.errors[:body].first, 'unauthorized variables'
      assert_includes @template_text.errors[:body].first, 'unauthorized_var'
    end

    test 'validate_variables_in_body allows optional variables' do
      # Test that optional variables are allowed
      optional_vars = @template_text.optional_variables
      if optional_vars.empty?
        @template_text.variables = {
          'required' => @template_text.required_variables,
          'optional' => ['optional_field']
        }
        optional_vars = @template_text.optional_variables
      end

      @template_text.body = "Hello %<name>s, optional: %<#{optional_vars.first}>s"
      assert @template_text.valid?, 'Template should be valid with optional variables'
    end

    test 'validate_variables_in_body allows required variables' do
      # Test that required variables are allowed
      required_vars = @template_text.required_variables
      assert required_vars.any?, 'Template fixture should define at least one required variable for this test'

      @template_text.body = "Hello %<#{required_vars.first}>s"
      assert @template_text.valid?, 'Template should be valid with required variables'
    end

    test 'validate_variables_in_body rejects multiple unauthorized variables' do
      @template_text.body = "Hello %<name>s, bad1: %<bad_var_1>s, bad2: %<bad_var_2>s" # rubocop:disable Style/StringLiterals

      assert_not @template_text.valid?, 'Template should be invalid'
      error_message = @template_text.errors[:body].first
      assert_includes error_message, 'bad_var_1'
      assert_includes error_message, 'bad_var_2'
    end

    # --- locale ---

    test 'locale defaults to en' do
      assert_equal 'en', @template_text.locale
    end

    test 'name + format + locale must be unique together' do
      duplicate = build(:email_template, :text,
                        name: @template_text.name,
                        body: @template_text.body,
                        locale: 'en')
      assert_not duplicate.valid?
      assert duplicate.errors[:name].any?
    end

    test 'same name and format can coexist with different locales' do
      es_template = build(:email_template, :text,
                          name: @template_text.name,
                          body: @template_text.body,
                          locale: 'es')
      assert es_template.valid?
    end

    test 'updating body flags counterpart locale as needs_sync' do
      es_template = create(:email_template, :text,
                           name: @template_text.name,
                           body: @template_text.body,
                           locale: 'es')

      @template_text.update!(body: 'Updated body %<name>s.')
      es_template.reload

      assert es_template.needs_sync?
    end

    test 'template blocked from saving when needs_sync is true and content is unchanged' do
      @template_text.update_column(:needs_sync, true)
      @template_text.reload
      @template_text.description = 'New description only.'

      assert_not @template_text.valid?
      assert @template_text.errors[:base].any?
    end

    test 'template allowed to save when needs_sync is true but body is changing' do
      @template_text.update_column(:needs_sync, true)
      @template_text.reload

      assert @template_text.update(body: 'Fixed body %<name>s.')
      @template_text.reload
      assert_not @template_text.needs_sync?
    end
  end
end
