# frozen_string_literal: true

module MailerPartAssertions
  def decoded_text_part(email)
    (email.text_part || email).body.decoded
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include MailerPartAssertions
end
