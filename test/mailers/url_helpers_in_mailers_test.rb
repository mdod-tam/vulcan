# frozen_string_literal: true

require 'test_helper'

class UrlHelpersInMailersTest < ActionMailer::TestCase
  setup do
    # Generate random unique emails to avoid duplication
    random_suffix = SecureRandom.hex(6)

    # Set up application and related objects using factories with unique emails
    @user = create(:constituent, email: "url_test_user_#{random_suffix}@example.com")
    @application = create(:application, user: @user)

    # Create a proof review with approved status for the application
    @proof_review = create(:proof_review,
                           application: @application,
                           proof_type: 'income',
                           status: :approved,
                           admin: create(:admin, email: "url_test_admin_#{random_suffix}@example.com"))

    # Set up evaluation and related objects
    @evaluator = create(:evaluator, email: "url_test_evaluator_#{random_suffix}@example.com")
    @constituent = create(:constituent, email: "url_test_constituent_#{random_suffix}@example.com")

    # Create a separate application for the evaluation to avoid associations reusing the same email
    @eval_application = create(:application,
                               user: @constituent,
                               status: :in_progress)

    # Create evaluation with all explicit associations to avoid any factory defaults
    @evaluation = create(:evaluation,
                         evaluator: @evaluator,
                         constituent: @constituent,
                         application: @eval_application,
                         status: :requested)

    # Set up vendor with unique email
    @vendor = create(:vendor, email: "url_test_vendor_#{random_suffix}@example.com")

    # Configure default URL options for testing
    Rails.application.config.action_mailer.default_url_options = { host: 'test.example.com' }

    # Create the required email templates for multipart text emails
    create_templates_if_missing
  end

  test 'proof_rejected email contains absolute URLs' do
    # Create a mock for the text template that returns text-only content
    mock_template = mock('EmailTemplate')
    subject = 'Your Proof Was Rejected'
    body = 'http://test.example.com/dashboard'
    mock_template.stubs(:render).returns([subject, body])
    mock_template.stubs(:enabled?).returns(true)
    EmailTemplate.stubs(:find_by!).returns(mock_template)

    email = ApplicationNotificationsMailer.proof_rejected(@application, @proof_review)

    # We now only have text emails, not multipart
    assert_equal 'text/plain; charset=UTF-8', email.content_type
    assert_match(%r{http://test\.example\.com}, email.body.to_s)
  end

  test 'new_evaluation_assigned email contains absolute URLs' do
    # Create a mock for the text template that returns text-only content with all required variables
    mock_template = mock('EmailTemplate')
    subject = 'New Evaluation Assigned'
    body = 'You can view and update the evaluation here: http://test.example.com/evaluations/123'
    mock_template.stubs(:render).returns([subject, body])
    mock_template.stubs(:enabled?).returns(true)
    EmailTemplate.stubs(:find_by!).returns(mock_template)

    # Override status_box_text method to provide the missing value
    EvaluatorMailer.any_instance.stubs(:status_box_text).returns('[STATUS] New Assignment: Please review')

    email = EvaluatorMailer.with(evaluation: @evaluation).new_evaluation_assigned

    # We now only have text emails, not multipart
    assert_equal 'text/plain; charset=UTF-8', email.content_type
    assert_match(%r{http://test\.example\.com}, email.body.to_s)
  end

  private

  # Create any missing templates to ensure the tests can run
  def create_templates_if_missing
    template_names = %w[
      application_notifications_proof_rejected
      evaluator_mailer_new_evaluation_assigned
      email_header_text
      email_footer_text
    ]

    template_names.each do |name|
      next if EmailTemplate.exists?(name: name, format: :text)

      template_body = case name
                      when 'application_notifications_proof_rejected'
                        "Subject: Your proof was rejected\n\n%<header_text>s\n\nDear %<constituent_full_name>s,\n\nYour %<proof_type_formatted>s proof has been rejected by %<organization_name>s.\n\nRejection reason: %<rejection_reason>s\n\nPlease visit http://%<host>s/dashboard to resubmit.\n\n%<footer_text>s"
                      when 'evaluator_mailer_new_evaluation_assigned'
                        "Subject: New Evaluation\n\n%<header_text>s\n\nDear %<evaluator_full_name>s,\n\nA new evaluation has been assigned for constituent %<constituent_full_name>s.\n\nConstituent Details:\nEmail: %<constituent_email>s\nPhone: %<constituent_phone_formatted>s\nAddress: %<constituent_address_formatted>s\nDisabilities: %<constituent_disabilities_text_list>s\n\n%<status_box_text>s\n\nPlease visit %<evaluators_evaluation_url>s to view.\n\n%<footer_text>s"
                      when 'email_header_text'
                        "=== %<title>s ===\n\n"
                      when 'email_footer_text'
                        "\n\nThank you,\nThe MAT Team\nContact: %<contact_email>s"
                      end

      EmailTemplate.create!(
        name: name,
        format: :text,
        body: template_body,
        subject: "Test Subject for #{name}",
        description: "Test template for #{name}"
      )
    end
  end
end
