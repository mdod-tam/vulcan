# frozen_string_literal: true

require 'test_helper'

class NotificationComposerTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin, first_name: 'Admin', last_name: 'User')
    @constituent = create(:constituent, first_name: 'John', last_name: 'Doe')
    @application = create(:application, user: @constituent)
  end

  test 'generate message for proof_approved' do
    message = NotificationComposer.generate(
      'proof_approved',
      @application,
      @admin,
      { 'proof_type' => 'income' }
    )
    assert message.include?('Income approved for')
    assert message.include?(@application.id.to_s)
  end

  test 'generate message for proof_rejected with reason' do
    message = NotificationComposer.generate(
      'proof_rejected',
      @application,
      @admin,
      { 'proof_type' => 'residency', 'rejection_reason' => 'Illegible document' }
    )
    assert message.include?('Residency rejected for')
    assert message.include?(@application.id.to_s)
    assert message.include?('Illegible document')
  end

  test 'generate message for trainer_assigned' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    create(:training_session, application: @application, trainer: trainer, status: :scheduled, scheduled_for: 1.week.from_now)

    message = NotificationComposer.generate(
      'trainer_assigned',
      @application,
      trainer
    )
    assert message.include?('Jane Trainer assigned to train John Doe for')
    assert message.include?(@application.id.to_s)
  end

  test 'generate message for training_requested' do
    message = NotificationComposer.generate(
      'training_requested',
      @application,
      @constituent
    )
    assert message.include?('John Doe requested training for')
    assert message.include?(@application.id.to_s)
  end

  test 'generate messages for training session lifecycle notifications' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    training_session = create(:training_session, :scheduled, application: @application, trainer: trainer)

    {
      'training_scheduled' => 'scheduled training',
      'training_rescheduled' => 'rescheduled training',
      'training_cancelled' => 'cancelled training',
      'training_completed' => 'completed training'
    }.each do |action, verb_phrase|
      message = NotificationComposer.generate(
        action,
        training_session,
        trainer,
        { 'application_id' => @application.id }
      )

      assert message.include?("Jane Trainer #{verb_phrase} for John Doe for")
      assert message.include?(@application.id.to_s)
    end
  end

  test 'generate message for medical_certification_rejected with reason' do
    message = NotificationComposer.generate(
      'medical_certification_rejected',
      @application,
      @admin,
      { 'reason' => 'Missing signature' }
    )
    assert message.include?('Disability certification rejected for')
    assert message.include?(@application.id.to_s)
    assert message.include?('Missing signature')
  end

  test 'generate default message for unknown action' do
    message = NotificationComposer.generate(
      'some_new_action',
      @application,
      @admin
    )
    assert_equal "Some new action notification regarding Application ##{@application.id}.", message
  end

  test 'application_reference returns HTML link when notifiable has id' do
    composer = NotificationComposer.new('test', @application, @admin, {})
    result = composer.send(:application_reference)
    assert result.include?(@application.id.to_s)
    assert result.include?('<a')
    assert result.include?('</a>')
  end

  test 'application_reference returns Application missing when notifiable is nil' do
    composer = NotificationComposer.new('test', nil, @admin, {})
    assert_equal 'Application missing', composer.send(:application_reference)
  end

  test 'application_reference returns Application missing when notifiable has no id' do
    composer = NotificationComposer.new('test', Application.new(id: nil), @admin, {})
    assert_equal 'Application missing', composer.send(:application_reference)
  end

  test 'handles nil notifiable object gracefully' do
    message = NotificationComposer.generate('proof_approved', nil, @admin)
    assert_equal 'Proof approved for application missing.', message
  end
end
