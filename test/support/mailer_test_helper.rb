# frozen_string_literal: true

module MailerTestHelper
  def stub_application_needs_review_since
    @application.stubs(:needs_review_since).returns(4.days.ago)
  end
end
