# frozen_string_literal: true

module EmailTemplateMockHelper
  # Builds a mock template whose render interpolates variables with gsub, as EmailTemplate#render does.
  def mock_template(subject_format, body_format)
    template = mock('email_template')

    template.define_singleton_method(:render) do |**vars|
      rendered_body = body.dup
      rendered_subject = subject.dup

      vars.each do |key, value|
        rendered_body = rendered_body.gsub("%{#{key}}", value.to_s)
        rendered_body = rendered_body.gsub("%<#{key}>s", value.to_s)

        rendered_subject = rendered_subject.gsub("%{#{key}}", value.to_s)
        rendered_subject = rendered_subject.gsub("%<#{key}>s", value.to_s)
      end

      [rendered_subject, rendered_body]
    end
    template.define_singleton_method(:render_subject) { |**vars| render(**vars).first }

    template.stubs(:subject).returns(subject_format)
    template.stubs(:body).returns(body_format)

    template.stubs(:enabled?).returns(true)

    template
  end
end
