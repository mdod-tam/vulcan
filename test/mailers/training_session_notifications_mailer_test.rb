# frozen_string_literal: true

require 'test_helper'
require 'ostruct' # Keep ostruct for the Struct used below

class TrainingSessionNotificationsMailerTest < ActionMailer::TestCase
  # Helper to create mock templates that respond to render method
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}")

    # Stub the render method to return [rendered_subject, rendered_body]
    # This simulates what the real EmailTemplate.render method does
    template_instance.stubs(:render).with(any_parameters).returns do |**vars|
      # Handle trainer variables
      rendered_subject = subject_format
      rendered_body = if vars[:trainer_full_name] && vars[:constituent_full_name]
                        body_format.gsub('%<trainer_full_name>s', vars[:trainer_full_name])
                                   .gsub('%<constituent_full_name>s', vars[:constituent_full_name])
                      # Handle training scheduled variables
                      elsif vars[:constituent_name] && vars[:trainer_name] && vars[:scheduled_date]
                        body_format.gsub('%<constituent_name>s', vars[:constituent_name])
                                   .gsub('%<trainer_name>s', vars[:trainer_name])
                                   .gsub('%<scheduled_date>s', vars[:scheduled_date])
                      # Handle training completed variables
                      elsif vars[:constituent_name] && vars[:trainer_name] && vars[:completion_date]
                        body_format.gsub('%<constituent_name>s', vars[:constituent_name])
                                   .gsub('%<trainer_name>s', vars[:trainer_name])
                                   .gsub('%<completion_date>s', vars[:completion_date])
                      else
                        body_format
                      end

      [rendered_subject, rendered_body]
    end

    # Still stub subject and body for inspection if needed
    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)

    template_instance
  end

  setup do
    # Use factories instead of fixtures with unique emails for each test run
    @constituent = create(:constituent,
                          first_name: 'John',
                          last_name: 'Doe',
                          email: "john.doe.#{SecureRandom.hex(6)}@example.com")
    @trainer = create(:trainer,
                      first_name: 'Jane',
                      last_name: 'Smith',
                      email: "jane.smith.#{SecureRandom.hex(6)}@example.com")
    @application = create(:application, :in_progress, user: @constituent)

    # Create a mock training session with the necessary attributes
    @scheduled_for = 1.week.from_now
    @completed_at = Time.current

    # Stub the training session
    @training_session = Struct.new(
      :application, :trainer, :constituent, :scheduled_for, :completed_at, :status, :id
    ).new(
      @application, @trainer, @constituent, @scheduled_for, @completed_at, :scheduled, 1
    )

    # Use the mock_template helper for templates
    @trainer_assigned_template = mock_template(
      'Mock New Training Assignment - App %<application_id>s',
      'Mock Body for %<trainer_full_name>s about %<constituent_full_name>s'
    )

    @training_scheduled_template = mock_template(
      'Mock Training Scheduled - App %<application_id>s',
      'Mock Body for %<constituent_name>s with %<trainer_name>s on %<scheduled_date>s'
    )

    @training_completed_template = mock_template(
      'Mock Training Completed - App %<application_id>s',
      'Mock Body for %<constituent_name>s with %<trainer_name>s on %<completion_date>s'
    )

    # Per project strategy, HTML emails are not used. Only stub for :text format.
    # If the mailer attempts to find_by!(format: :html), it should fail (e.g., RecordNotFound)
    # as no HTML templates should be seeded for these, and we provide no stub.

    # Stub EmailTemplate.find_by! for text format only
    EmailTemplate.stubs(:find_by!).with(name: 'training_session_notifications_trainer_assigned',
                                        format: :text, locale: 'en').returns(@trainer_assigned_template)
    EmailTemplate.stubs(:find_by!).with(name: 'training_session_notifications_training_scheduled',
                                        format: :text, locale: 'en').returns(@training_scheduled_template)
    EmailTemplate.stubs(:find_by!).with(name: 'training_session_notifications_training_completed',
                                        format: :text, locale: 'en').returns(@training_completed_template)
  end

  test 'trainer_assigned' do
    # Create a specific stub for this test to ensure consistent results
    expected_text = "Mock Body for #{@trainer.full_name} about #{@constituent.full_name}"
    trainer_assigned_template = mock('trainer_assigned_specific')
    trainer_assigned_template.stubs(:render).returns(['Trainer assigned', expected_text])

    # Override stub for this test
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'en')
                 .returns(trainer_assigned_template)

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      TrainingSessionNotificationsMailer.with(training_session: @training_session).trainer_assigned.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@trainer.email], email.to
    assert_equal 'Trainer assigned', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end

  test 'training_scheduled' do
    # Create a specific stub for this test to ensure consistent results
    expected_date = @scheduled_for.strftime('%B %d, %Y')
    expected_text = "Mock Body for #{@constituent.full_name} with #{@trainer.full_name} on #{expected_date}"
    training_scheduled_template = mock('training_scheduled_specific')
    training_scheduled_template.stubs(:render).returns(['Training scheduled', expected_text])

    # Re-stub for this test only
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_training_scheduled', format: :text, locale: 'en')
                 .returns(training_scheduled_template)

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      TrainingSessionNotificationsMailer.with(training_session: @training_session).training_scheduled.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent.email], email.to
    assert_equal 'Training scheduled', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end

  test 'training_completed' do
    # Create a specific stub for this test to ensure consistent results
    expected_date = @completed_at.strftime('%B %d, %Y')
    expected_text = "Mock Body for #{@constituent.full_name} with #{@trainer.full_name} on #{expected_date}"
    training_completed_template = mock('training_completed_specific')
    training_completed_template.stubs(:render).returns(['Training completed', expected_text])

    # Re-stub for this test only
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_training_completed', format: :text, locale: 'en')
                 .returns(training_completed_template)

    # Update the status to completed
    @training_session.status = :completed

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      TrainingSessionNotificationsMailer.with(training_session: @training_session).training_completed.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent.email], email.to
    assert_equal 'Training completed', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end
end
