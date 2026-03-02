# frozen_string_literal: true

require 'test_helper'

module Letters
  class TextTemplateToPdfServiceTest < ActiveSupport::TestCase
    setup do
      @user = create(:constituent, email: "test-template-#{SecureRandom.hex(4)}@example.com")
      # Find existing template to avoid "Name has already been taken" error
      EmailTemplate.where(name: 'application_notifications_account_created').destroy_all

      # Create template with all required variables
      @template = create(:email_template,
                         name: 'application_notifications_account_created',
                         subject: 'Your account has been created',
                         body: "Hello %<constituent_first_name>s,\n\n" \
                               "Welcome to the service!\n\n" \
                               "Your username is %<constituent_email>s.\n" \
                               "Your temporary password is %<temp_password>s.\n\n" \
                               "Please login at %<sign_in_url>s soon.\n\n" \
                               "%<header_text>s\n" \
                               "%<footer_text>s\n",
                        variables: {
                          'required' => %w[constituent_first_name constituent_email temp_password sign_in_url header_text footer_text],
                           'optional' => []
                        },
                         format: :text)

      @variables = {
        constituent_first_name: @user.first_name,
        constituent_email: @user.email,
        temp_password: 'SecurePassword123',
        sign_in_url: 'https://example.com/sign_in',
        header_text: 'Header text for testing',
        footer_text: 'Footer text for testing'
      }
    end

    test 'generates PDF from database template' do
      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: @variables
      )

      pdf_file = service.generate_pdf

      # Basic checks that the PDF was generated
      assert pdf_file.is_a?(Tempfile)
      assert_match '%PDF', pdf_file.read[0, 10] # PDF files start with %PDF

      # Close the file to prevent resource leaks
      pdf_file.close
      pdf_file.unlink
    end

    test 'correctly substitutes variables in template' do
      # Create a service with the real template
      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: @variables
      )

      # Call the method under test
      result = service.send(:render_template_with_variables)

      # Verify that all variables were substituted
      assert_includes result, "Hello #{@user.first_name},"
      assert_includes result, "Your username is #{@user.email}."
      assert_includes result, 'Your temporary password is SecurePassword123.'
      assert_includes result, 'Please login at https://example.com/sign_in soon.'
      assert_includes result, 'Header text for testing'
      assert_includes result, 'Footer text for testing'

      # Verify there are no remaining placeholders
      assert_no_match(/%<\w+>s/, result)
    end

    test 'returns nil when template not found' do
      service = TextTemplateToPdfService.new(
        template_name: 'non_existent_template',
        recipient: @user,
        variables: @variables
      )

      pdf_file = service.generate_pdf
      assert_nil pdf_file
    end

    test 'correctly queues item for printing' do
      # Skip this test as it requires accessing private methods or stubbing PrintQueueItem
      # which varies between testing frameworks
      skip 'Tested through integration tests'
    end
  end
end
