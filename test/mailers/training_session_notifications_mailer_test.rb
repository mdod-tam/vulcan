# frozen_string_literal: true

require 'test_helper'

class TrainingSessionNotificationsMailerTest < ActionMailer::TestCase
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}")

    # The mock preserves the subject/body pair returned by EmailTemplate#render.
    template_instance.stubs(:enabled?).returns(true)
    template_instance.stubs(:render).with(any_parameters).returns do |**vars|
      rendered_subject = subject_format
      rendered_body = if vars[:trainer_full_name] && vars[:constituent_full_name]
                        body_format.gsub('%<trainer_full_name>s', vars[:trainer_full_name])
                                   .gsub('%<constituent_full_name>s', vars[:constituent_full_name])
                      elsif vars[:constituent_name] && vars[:trainer_name] && vars[:scheduled_date]
                        body_format.gsub('%<constituent_name>s', vars[:constituent_name])
                                   .gsub('%<trainer_name>s', vars[:trainer_name])
                                   .gsub('%<scheduled_date>s', vars[:scheduled_date])
                      else
                        body_format
                      end

      [rendered_subject, rendered_body]
    end

    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:render_subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)

    template_instance
  end

  setup do
    @constituent = create(:constituent,
                          first_name: 'John',
                          last_name: 'Doe',
                          email: "john.doe.#{SecureRandom.hex(6)}@example.com")
    @trainer = create(:trainer,
                      first_name: 'Jane',
                      last_name: 'Smith',
                      email: "jane.smith.#{SecureRandom.hex(6)}@example.com")
    @application = create(:application, :in_progress, user: @constituent)

    @scheduled_for = 1.week.from_now
    @training_session = Struct.new(
      :application, :trainer, :constituent, :scheduled_for, :completed_at, :status, :id
    ).new(
      @application, @trainer, @constituent, @scheduled_for, @completed_at, :scheduled, 1
    )

    @trainer_assigned_template = mock_template(
      'Mock New Training Assignment - App %<application_id>s',
      'Mock Body for %<trainer_full_name>s about %<constituent_full_name>s'
    )

    @training_scheduled_template = mock_template(
      'Mock Training Scheduled - App %<application_id>s',
      'Mock Body for %<constituent_name>s with %<trainer_name>s on %<scheduled_date>s'
    )

    # Only lookups for text templates match these stubs. An HTML lookup has no matching stub.

    EmailTemplate.stubs(:find_by!).with(name: 'training_session_notifications_trainer_assigned',
                                        format: :text, locale: 'en').returns(@trainer_assigned_template)
    EmailTemplate.stubs(:find_by!).with(name: 'training_session_notifications_training_scheduled',
                                        format: :text, locale: 'en').returns(@training_scheduled_template)
  end

  test 'trainer_assigned' do
    expected_text = "Mock Body for #{@trainer.full_name} about #{@constituent.full_name}"
    trainer_assigned_template = mock('trainer_assigned_specific')
    trainer_assigned_template.stubs(:subject).returns('Trainer assigned')
    trainer_assigned_template.stubs(:render_subject).returns('Trainer assigned')
    trainer_assigned_template.stubs(:render).returns(['Trainer assigned', expected_text])
    trainer_assigned_template.stubs(:enabled?).returns(true)

    EmailTemplate.unstub(:find_by!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'en')
                 .returns(trainer_assigned_template)

    emails = capture_emails do
      TrainingSessionNotificationsMailer.trainer_assigned(@training_session).deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@trainer.email], email.to
    assert_equal 'Trainer assigned', email.subject

    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_equal 'text/plain; charset=UTF-8', email.content_type

    assert_includes email.body.to_s, expected_text
  end

  test 'trainer_assigned uses English template for Spanish locale trainer' do
    @trainer.update!(locale: 'es')
    expected_text = "English body for #{@trainer.full_name} about #{@constituent.full_name}"
    english_template = mock('trainer_assigned_english_specific')
    english_template.stubs(:subject).returns('English trainer assignment')
    english_template.stubs(:render_subject).returns('English trainer assignment')
    english_template.stubs(:render).returns(['English trainer assignment', expected_text])
    english_template.stubs(:enabled?).returns(true)

    EmailTemplate.unstub(:find_by!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'en')
                 .returns(english_template)

    emails = capture_emails do
      TrainingSessionNotificationsMailer.trainer_assigned(@training_session).deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first
    assert_equal [@trainer.email], email.to
    assert_equal 'English trainer assignment', email.subject
    assert_includes email.body.to_s, expected_text
  end

  test 'trainer_assigned footer uses program name fallback' do
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.where(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'en').destroy_all
    EmailTemplate.create!(
      name: 'training_session_notifications_trainer_assigned',
      format: :text,
      locale: 'en',
      subject: 'Trainer assigned',
      description: 'Trainer assigned footer test template',
      body: <<~TEXT,
        %<trainer_full_name>s
        %<constituent_language>s
        %<constituent_contact_method>s
        %<constituent_communication_modality>s
        %<footer_text>s
      TEXT
      variables: {
        'required' => %w[
          trainer_full_name
          constituent_language
          constituent_contact_method
          constituent_communication_modality
          footer_text
        ],
        'optional' => []
      },
      version: 1
    )
    @constituent.update!(locale: 'es', phone_type: 'videophone', preferred_means_of_communication: 'asl')
    Policy.stubs(:get).returns(nil)
    Policy.stubs(:get).with('support_email').returns('mat.program1@maryland.gov')
    Policy.stubs(:get).with('organization_name').returns(nil)

    email = TrainingSessionNotificationsMailer.trainer_assigned(@training_session).deliver_now

    assert_includes email.body.to_s, @trainer.full_name
    assert_includes email.body.to_s, 'Spanish'
    assert_includes email.body.to_s, 'Videophone (ASL)'
    assert_includes email.body.to_s, 'American Sign Language (ASL)'
    assert_not_includes email.body.to_s, '{english:'
    assert_includes email.body.to_s, 'Maryland Accessible Telecommunications Program'
    assert_not_includes email.body.to_s, 'MAT-Vulcan'
  end

  test 'training_scheduled' do
    expected_date = @scheduled_for.strftime('%B %d, %Y')
    expected_text = "Mock Body for #{@constituent.full_name} with #{@trainer.full_name} on #{expected_date}"
    training_scheduled_template = mock('training_scheduled_specific')
    training_scheduled_template.stubs(:subject).returns('Training scheduled')
    training_scheduled_template.stubs(:render_subject).returns('Training scheduled')
    training_scheduled_template.stubs(:render).returns(['Training scheduled', expected_text])
    training_scheduled_template.stubs(:enabled?).returns(true)

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'training_session_notifications_training_scheduled', format: :text, locale: 'en')
                 .returns(training_scheduled_template)

    emails = capture_emails do
      TrainingSessionNotificationsMailer.training_scheduled(@training_session).deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent.email], email.to
    assert_equal 'Training scheduled', email.subject

    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    assert_includes email.body.to_s, expected_text
  end

  test 'training_scheduled renders a real Liquid text template' do
    EmailTemplate.unstub(:find_by!)
    expected_date = @scheduled_for.strftime('%B %d, %Y')
    create_real_text_email_template(
      name: 'training_session_notifications_training_scheduled',
      subject: 'Training {{ application_id }}',
      body: '{{ constituent_name }} with {{ trainer_name }} on {{ scheduled_date }}',
      required: %w[application_id constituent_name trainer_name scheduled_date]
    )

    email = TrainingSessionNotificationsMailer.training_scheduled(@training_session).deliver_now

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent.email], email.to
    assert_equal "Training #{@application.id}", email.subject
    assert_includes email.body.to_s, @constituent.full_name
    assert_includes email.body.to_s, @trainer.full_name
    assert_includes email.body.to_s, expected_date
  end
end
