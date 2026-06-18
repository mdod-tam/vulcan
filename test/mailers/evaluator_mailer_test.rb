# frozen_string_literal: true

require 'test_helper'
require_relative 'email_template_mock_helper'

class EvaluatorMailerTest < ActionMailer::TestCase
  include EmailTemplateMockHelper

  setup do
    # Stored templates remain text-only until explicit HTML template support is added.

    # Create specific mock templates for each mailer method
    new_evaluation_assigned_mock = mock_template(
      'New Evaluation Assigned',
      'Text body for evaluation assigned to %<evaluator_full_name>s for %<constituent_full_name>s. Contact: %<constituent_contact_method>s. Language: %<constituent_preferred_language>s. Modality: %<constituent_communication_modality>s. Delivery: %<constituent_delivery_preference>s. %<status_box_text>s %<footer_text>s'
    )

    evaluation_submission_mock = mock_template(
      'Evaluation has been Submitted',
      'Recommended products: %<recommended_products_text_list>s. %<footer_text>s'
    )

    # Stub EmailTemplate.find_by! for text format only
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'evaluator_mailer_new_evaluation_assigned', format: :text, locale: 'en')
                 .returns(new_evaluation_assigned_mock)

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en')
                 .returns(evaluation_submission_mock)

    # Create test data using FactoryBot
    @evaluation = create(:evaluation)
    @evaluator = @evaluation.evaluator
    @constituent = @evaluation.constituent
    @constituent.update!(phone_type: 'text', preferred_means_of_communication: 'ASL', communication_preference: 'email')
    @alpha_product = create(:product, name: 'Alpha Communicator')
    @zeta_product = create(:product, name: 'Zeta Tablet')
    @evaluation.recommended_product_ids = [@zeta_product.id, @alpha_product.id]
    @application = @evaluation.application
  end

  test 'new_evaluation_assigned' do
    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      EvaluatorMailer.with(evaluation: @evaluation).new_evaluation_assigned.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@evaluator.email], email.to
    assert_equal 'New Evaluation Assigned', email.subject

    # Check that the email body contains expected text
    body = decoded_text_part(email)
    expected_text = "Text body for evaluation assigned to #{@evaluator.full_name} for #{@constituent.full_name}"
    assert_includes body, expected_text
    assert_includes body, 'Contact: Text me'
    assert_includes body, 'Language: English'
    assert_includes body, 'Modality: ASL'
    assert_includes body, 'Delivery: Email'
  end

  test 'new_evaluation_assigned uses English template for Spanish locale evaluator' do
    @evaluator.update!(locale: 'es')

    emails = capture_emails do
      EvaluatorMailer.with(evaluation: @evaluation).new_evaluation_assigned.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first
    assert_equal [@evaluator.email], email.to
    assert_equal 'New Evaluation Assigned', email.subject
  end

  test 'evaluation_submission_confirmation' do
    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      EvaluatorMailer.with(evaluation: @evaluation).evaluation_submission_confirmation.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent.email], email.to
    assert_equal 'Evaluation has been Submitted', email.subject

    # Check that the email body contains expected content from the mock
    body = decoded_text_part(email)
    assert_includes body, "#{@alpha_product.name}\n#{@zeta_product.name}"
    assert_not_includes body, "- #{@alpha_product.name}"
    assert_not_includes body, 'equipment order'
  end

  test 'evaluation_submission_confirmation generates letter when preference is letter' do
    # Set constituent communication preference to 'letter'
    @constituent.update!(communication_preference: 'letter')

    # Expect TextTemplateToPdfService to be called
    Letters::TextTemplateToPdfService.any_instance.expects(:queue_for_printing).once

    # Call the mailer method
    email = EvaluatorMailer.with(evaluation: @evaluation).evaluation_submission_confirmation

    # Letter-routing returns noop delivery object; no outbound email should be sent.
    assert_no_emails do
      email.deliver_later
    end

    # Basic email assertions can still be included if desired
    assert_match 'Evaluation has been Submitted', email.subject
  end
end
