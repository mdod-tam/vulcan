# frozen_string_literal: true

require 'nokogiri'

module MailerPartAssertions
  def decoded_text_part(email)
    (email.text_part || email).body.decoded
  end

  def decoded_html_part(email)
    email.html_part&.body&.decoded
  end

  def assert_accessible_html_link(email, href:, text:)
    html = decoded_html_part(email)

    assert html.present?, 'Expected email to include an HTML part'
    assert Nokogiri::HTML.fragment(html).css('a').any? { |link| link['href'] == href && link.text == text },
           "Expected HTML part to include link #{text.inspect} to #{href.inspect}"
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include MailerPartAssertions
end
