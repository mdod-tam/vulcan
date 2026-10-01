# frozen_string_literal: true

require 'test_helper'

module Mailers
  class SharedPartialHelpersTest < ActiveSupport::TestCase
    test 'email footer falls back to the program support email, not a placeholder' do
      footer = EvaluatorMailer.new.send(:footer_text)

      assert_includes footer, ProgramContact.support_email
      assert_not_includes footer, 'example.com'
    end

    test 'a later render on the same thread sees an edited shared header' do
      header = header_template('First header %<title>s')

      assert_equal 'First header Welcome', render_header(EvaluatorMailer.new)

      header.update!(body: 'Second header %<title>s')

      assert_equal 'Second header Welcome', render_header(EvaluatorMailer.new)
    end

    test 'a failed shared header lookup does not stick to the thread' do
      header_template('Header %<title>s')
      EmailTemplate.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished)

      assert_match(/\AError rendering template/, render_header(EvaluatorMailer.new))

      EmailTemplate.unstub(:find_by)

      assert_equal 'Header Welcome', render_header(EvaluatorMailer.new)
    end

    test 'header title renders the template subject with supplied values kept literal' do
      # rubocop:disable Style/FormatStringToken
      template = create(
        :email_template,
        :text,
        subject: 'Application %<application_id>s',
        body: 'Body %<application_id>s',
        variables: { 'required' => ['application_id'], 'optional' => [] },
        syntax: :legacy_percent
      )

      title = EvaluatorMailer.new.send(
        :header_title_from_template_subject,
        template: template,
        subject_variables: { application_id: '12\\0 %{x}' }
      )

      assert_equal 'Application 12\\0 %{x}', title
      # rubocop:enable Style/FormatStringToken
    end

    private

    def header_template(body)
      template = EmailTemplate.find_or_initialize_by(name: 'email_header_text', format: :text, locale: 'en')
      template.assign_attributes(
        subject: 'Header',
        body: body,
        description: 'Shared header',
        variables: { 'required' => ['title'], 'optional' => [] },
        syntax: :legacy_percent
      )
      template.save!
      template
    end

    def render_header(mailer)
      mailer.send(:render_email_template, 'email_header_text', :text, title: 'Welcome', locale: 'en')
    end
  end
end
