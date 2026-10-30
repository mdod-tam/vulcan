# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class SampleDataTest < ActiveSupport::TestCase
    test 'preview sample data uses the default locale template in the requested format' do
      name = "preview_locale_#{SecureRandom.hex(4)}"
      english = create(:email_template, :text, name: name, locale: 'en', subject: 'Notice', body: '%<notice_detail>s',
                                               variables: { 'required' => ['notice_detail'], 'optional' => [] })
      create(:email_template, :html, name: name, locale: 'es', subject: 'Aviso', body: '<p>%<html_detail>s</p>',
                                     variables: { 'required' => ['html_detail'], 'optional' => [] })

      sample_data = EmailTemplates::SampleData.for_template_name(name, locale: 'es', format: :text)

      assert_equal ['Notice', 'Sample Notice Detail'], english.render(**sample_data.symbolize_keys)
      assert_not sample_data.key?('html_detail')
    end

    test 'a missing preview template still supplies the base program contact data' do
      sample_data = EmailTemplates::SampleData.for_template_name("missing_preview_#{SecureRandom.hex(4)}", locale: 'es')

      assert_equal ProgramContact.support_email, sample_data['footer_contact_email']
    end

    test 'seeded maximum-rejection previews render without a reapply date contract' do
      template_name = 'application_notifications_max_rejections_reached'
      EmailTemplate.where(name: template_name, format: :text).destroy_all

      %w[en es].each do |locale|
        load Rails.root.join("db/seeds/email_templates/#{template_name}#{'_es' if locale == 'es'}.rb")
        template = EmailTemplate.find_with_locale(name: template_name, format: :text, locale: locale)
        sample_data = EmailTemplates::SampleData.for_template_name(template_name, locale: locale)
        _subject, body = template.render(**sample_data.symbolize_keys)

        assert_not sample_data.key?('reapply_date_formatted')
        assert_not_includes template.variables.fetch('required'), 'reapply_date_formatted'
        assert_includes body, locale == 'es' ? 'Si presenta una nueva solicitud' : 'If you submit a new application'
        assert_no_match(/%[<{]\w+[>}]s?/, body)
      end
    end
  end
end
