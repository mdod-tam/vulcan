# frozen_string_literal: true

module EmailTemplateMockHelper
  # Helper to create mock templates that performs interpolation
  # Mimics the behavior of EmailTemplate.render() which uses gsub for substitution
  def mock_template(subject_format, body_format)
    template = mock('email_template')

    # Stub render to perform gsub-based interpolation matching the real EmailTemplate.render behavior
      # Stub the render method to perform interpolation
      template.define_singleton_method(:render) do |**vars|
        rendered_body = body.dup
        rendered_subject = subject.dup

        vars.each do |key, value|
          # Handle both "%{key}" and "%<key>s" format strings
          rendered_body = rendered_body.gsub("%{#{key}}", value.to_s)
          rendered_body = rendered_body.gsub("%<#{key}>s", value.to_s)

          rendered_subject = rendered_subject.gsub("%{#{key}}", value.to_s)
          rendered_subject = rendered_subject.gsub("%<#{key}>s", value.to_s)
        end

        [rendered_subject, rendered_body]
      end

    # Stub subject and body for inspection if needed
    template.stubs(:subject).returns(subject_format)
    template.stubs(:body).returns(body_format)

    template.stubs(:enabled?).returns(true)

    template
  end
end
