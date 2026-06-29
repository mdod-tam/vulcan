# frozen_string_literal: true

module EmailTemplateRenderingTestHelper
  def create_real_text_email_template(name:, subject:, body:, required:, optional: [], syntax: :liquid, locale: 'en')
    EmailTemplate.where(name: name, format: :text, locale: locale).destroy_all

    create(:email_template, :text,
           name: name,
           locale: locale,
           syntax: syntax,
           subject: subject,
           body: body,
           variables: {
             'required' => required.map(&:to_s),
             'optional' => optional.map(&:to_s)
           },
           enabled: true)
  end
end

ActiveSupport::TestCase.include EmailTemplateRenderingTestHelper
