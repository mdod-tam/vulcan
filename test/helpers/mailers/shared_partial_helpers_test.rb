# frozen_string_literal: true

require 'test_helper'

module Mailers
  class SharedPartialHelpersTest < ActiveSupport::TestCase
    test 'email footer falls back to the program support email, not a placeholder' do
      footer = EvaluatorMailer.new.send(:footer_text)

      assert_includes footer, ProgramContact.support_email
      assert_not_includes footer, 'example.com'
    end
  end
end
