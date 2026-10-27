# frozen_string_literal: true

require 'test_helper'

class UrlHelpersInMailersTest < ActionMailer::TestCase
  setup do
    # Unique emails keep records from colliding across tests.
    random_suffix = SecureRandom.hex(6)

    @user = create(:constituent, email: "url_test_user_#{random_suffix}@example.com")
    @application = create(:application, user: @user)

    @proof_review = create(:proof_review,
                           application: @application,
                           proof_type: 'income',
                           status: :approved,
                           admin: create(:admin, email: "url_test_admin_#{random_suffix}@example.com"))

    @evaluator = create(:evaluator, email: "url_test_evaluator_#{random_suffix}@example.com")
    @constituent = create(:constituent, email: "url_test_constituent_#{random_suffix}@example.com")

    # A separate application keeps associations from reusing the same email.
    @eval_application = create(:application,
                               user: @constituent,
                               status: :in_progress)

    # Explicit associations keep factory defaults out of the evaluation.
    @evaluation = create(:evaluation,
                         evaluator: @evaluator,
                         constituent: @constituent,
                         application: @eval_application,
                         status: :requested)

    @vendor = create(:vendor, email: "url_test_vendor_#{random_suffix}@example.com")

    @original_default_url_options = Rails.application.config.action_mailer.default_url_options&.dup
    Rails.application.config.action_mailer.default_url_options = { host: 'test.example.com' }

    create_templates_if_missing
  end

  teardown do
    Rails.application.config.action_mailer.default_url_options = @original_default_url_options
  end

  test 'proof_rejected email contains absolute URLs' do
    mock_template = mock('EmailTemplate')
    subject = 'Your Proof Was Rejected'
    body = "Proof resubmission link:\nhttp://test.example.com/dashboard"
    mock_template.stubs(:subject).returns(subject)
    mock_template.stubs(:render_subject).returns(subject)
    mock_template.stubs(:render).returns([subject, body])
    mock_template.stubs(:enabled?).returns(true)
    EmailTemplate.stubs(:find_by!).returns(mock_template)

    email = ApplicationNotificationsMailer.proof_rejected(@application, @proof_review)

    assert_match(%r{http://test\.example\.com}, decoded_text_part(email))
  end

  test 'new_evaluation_assigned email contains absolute URLs' do
    mock_template = mock('EmailTemplate')
    subject = 'New Evaluation Assigned'
    body = "Evaluator evaluation link:\nhttp://test.example.com/evaluations/123"
    mock_template.stubs(:subject).returns(subject)
    mock_template.stubs(:render_subject).returns(subject)
    mock_template.stubs(:render).returns([subject, body])
    mock_template.stubs(:enabled?).returns(true)
    EmailTemplate.stubs(:find_by!).returns(mock_template)

    EvaluatorMailer.any_instance.stubs(:status_box_text).returns('[STATUS] New Assignment: Please review')

    email = EvaluatorMailer.with(assignment_notice_params(@evaluation, @evaluation.evaluator)).new_evaluation_assigned

    assert_match(%r{http://test\.example\.com}, decoded_text_part(email))
  end

  test 'password reset email uses canonical configured URL options' do
    EmailTemplate.where(name: 'user_mailer_password_reset', format: :text).delete_all
    create(:email_template, :text,
           name: 'user_mailer_password_reset',
           locale: 'en',
           subject: 'Reset password',
           body: 'Reset link: %<reset_url>s for %<user_email>s',
           variables: {
             'required' => %w[user_email reset_url],
             'optional' => []
           })
    @user.stubs(:generate_token_for).with(:password_reset).returns('canonical-reset-token')

    email = UserMailer.with(user: @user).password_reset

    assert_includes decoded_text_part(email),
                    'Reset link: http://test.example.com/password/edit?token=canonical-reset-token'
  end

  test 'password reset email fails fast for unsafe production canonical host' do
    Rails.application.config.action_mailer.default_url_options = { host: 'example.com', protocol: 'https' }
    Rails.env.stubs(:production?).returns(true)

    error = assert_raises(ArgumentError) do
      UserMailer.with(user: @user).password_reset.deliver_now
    end

    assert_equal 'Canonical public URL host is not configured', error.message
  end

  private

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
