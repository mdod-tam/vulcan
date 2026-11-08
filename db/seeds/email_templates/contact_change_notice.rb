# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'contact_change_notice', format: :text, locale: 'en') do |template|
  template.subject = 'Account contact security notice'
  template.description = 'Account-owner notice sent to an immutable email snapshot.'
  template.body = <<~TEXT
    %<message>s

    If you did not request this change, contact %<support_email>s immediately.
  TEXT
  template.variables = { 'required' => %w[message support_email], 'optional' => [] }
  template.version = 1
end
