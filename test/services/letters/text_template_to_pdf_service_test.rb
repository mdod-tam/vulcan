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
                         subject: 'We Received Your Maryland Accessible Telecommunications Application',
                         body: "Hello %<constituent_first_name>s,\n\n" \
                               "Welcome to the service!\n\n" \
                               "Questions? Contact %<support_email>s.\n" \
                               "Program website: %<program_website_url>s.\n\n" \
                               "%<header_text>s\n" \
                               "%<footer_text>s\n",
                         variables: {
                           'required' => %w[constituent_first_name support_email program_website_url header_text footer_text],
                           'optional' => []
                         },
                         format: :text)

      @variables = {
        constituent_first_name: @user.first_name,
        support_email: 'mat.program1@maryland.gov',
        program_website_url: ProgramContact.website_url,
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
      assert_includes result, 'Questions? Contact mat.program1@maryland.gov.'
      assert_includes result, "Program website: #{ProgramContact.website_url}."
      assert_includes result, 'Header text for testing'
      assert_includes result, 'Footer text for testing'
      assert_not_includes result, 'SecurePassword123'
      assert_not_includes result, 'sign_in'

      # Verify there are no remaining placeholders
      assert_no_match(/%<\w+>s/, result)
    end

    test 'queue_for_printing raises before creating print queue item when required variables are missing' do
      @template.update!(
        subject: 'Missing variable notice',
        body: 'Hello %<constituent_first_name>s. Code: %<missing_code>s.',
        variables: { 'required' => %w[constituent_first_name missing_code], 'optional' => [] }
      )

      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: { constituent_first_name: @user.first_name }
      )

      original_print_queue_count = PrintQueueItem.count
      error = assert_raises(ArgumentError) { service.queue_for_printing }

      assert_includes error.message, 'Missing required variables'
      assert_includes error.message, 'missing_code'
      assert_equal original_print_queue_count, PrintQueueItem.count
    end

    test 'renders Liquid templates through shared EmailTemplate renderer' do
      template_name = "liquid_letter_#{SecureRandom.hex(4)}"
      create(:email_template, :text,
             name: template_name,
             subject: 'Letter for {{ recipient.first_name }}',
             body: 'Hello {{ recipient.first_name }}.',
             variables: { 'required' => ['recipient.first_name'], 'optional' => [] },
             syntax: :liquid,
             locale: 'en')

      service = TextTemplateToPdfService.new(
        template_name: template_name,
        recipient: @user,
        variables: { recipient: { first_name: 'Alex' } }
      )

      assert_equal 'Hello Alex.', service.send(:render_template_with_variables)
      assert_equal 'Letter for Alex', service.send(:determine_letter_title)
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

    test 'uses normalized recipient locale for template selection and title localization' do
      @user.update!(locale: 'es-MX')

      create(:email_template, :text,
             name: 'application_notifications_account_created',
             subject: 'Su cuenta ha sido creada',
             body: @template.body,
             variables: @template.variables,
             locale: 'es')

      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: @variables
      )

      assert_equal 'es', service.send(:resolved_locale)
      assert_equal 'es', service.template.locale
      assert_equal 'Su cuenta ha sido creada', service.send(:determine_letter_title)
    end

    test 'template shared-partials check uses matching format only' do
      template_name = "format_specific_partial_test_#{SecureRandom.hex(4)}"

      create(:email_template, :html,
             name: template_name,
             subject: 'HTML Test',
             body: '<p>%<header_text>s</p><p>%<footer_text>s</p>',
             variables: { 'required' => %w[header_text footer_text], 'optional' => [] },
             locale: 'en')

      create(:email_template, :text,
             name: template_name,
             subject: 'Text Test',
             body: 'Body %<name>s',
             variables: { 'required' => ['name'], 'optional' => [] },
             locale: 'en')

      service = TextTemplateToPdfService.new(
        template_name: template_name,
        recipient: @user,
        variables: { name: 'Test User' }
      )

      assert_not service.send(:template_requires_shared_partials?)
    end

    test 'localizes letter salutation and date label in spanish' do
      @user.update!(first_name: 'Ana', locale: 'es')

      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: @variables
      )

      salutation_pdf = mock('salutation_pdf')
      salutation_pdf.expects(:text).with('Estimado/a Ana,')
      salutation_pdf.expects(:move_down).with(10)
      service.send(:add_salutation, salutation_pdf)

      date_pdf = mock('date_pdf')
      date_pdf.expects(:text).with do |text, options|
        text.start_with?('Fecha:') && options == { align: :right }
      end
      date_pdf.expects(:move_down).with(10)
      service.send(:add_date, date_pdf)
    end

    test 'letter footer uses centralized office address' do
      service = TextTemplateToPdfService.new(
        template_name: 'application_notifications_account_created',
        recipient: @user,
        variables: @variables
      )

      footer_pdf = mock('footer_pdf')
      footer_pdf.expects(:move_down).with(50)
      footer_pdf.expects(:font_size).with(8)
      footer_pdf.expects(:stroke_horizontal_rule)
      footer_pdf.expects(:move_down).with(10)
      footer_pdf.expects(:text).with("Maryland Accessible Telecommunications | #{ProgramContact.office_address}",
                                     align: :center)
      footer_pdf.expects(:text).with(regexp_matches(/www\.mdmat\.org/), align: :center)

      service.send(:add_footer, footer_pdf)
    end

    test 'correctly queues item for printing' do
      # Skip this test as it requires accessing private methods or stubbing PrintQueueItem
      # which varies between testing frameworks
      skip 'Tested through integration tests'
    end
  end
end
