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

  # Loads the production seed rows (both locales when present) for real-rendering tests.
  def load_seeded_email_templates(*names)
    names.each do |name|
      EmailTemplate.where(name: name, format: :text).destroy_all
      ['', '_es'].each do |suffix|
        path = Rails.root.join("db/seeds/email_templates/#{name}#{suffix}.rb")
        load path if path.exist?
      end
    end
  end
end

ActiveSupport::TestCase.include EmailTemplateRenderingTestHelper
