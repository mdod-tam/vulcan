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
    assert_equal "Income approved for application ##{@application.id}.", message
  end

  test 'generate message for proof_rejected with reason' do
    message = NotificationComposer.generate(
      'proof_rejected',
      @application,
      @admin,
      { 'proof_type' => 'residency', 'rejection_reason' => 'Illegible document' }
    )
    assert_equal "Residency rejected for application ##{@application.id} - Illegible document.", message
  end

  test 'generate message for trainer_assigned' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    create(:training_session, application: @application, trainer: trainer, status: :scheduled, scheduled_for: 1.week.from_now)

    message = NotificationComposer.generate(
      'trainer_assigned',
      @application,
      trainer
    )
    assert_equal "Jane Trainer assigned to train John Doe for Application ##{@application.id} (Scheduled).", message
  end

  test 'generate message for medical_certification_rejected with reason' do
    message = NotificationComposer.generate(
      'medical_certification_rejected',
      @application,
      @admin,
      { 'reason' => 'Missing signature' }
    )
    assert_equal "Disability certification rejected for application ##{@application.id} - Missing signature.", message
  end

  test 'generate default message for unknown action' do
    message = NotificationComposer.generate(
      'some_new_action',
      @application,
      @admin
    )
    assert_equal "Some new action notification regarding Application ##{@application.id}.", message
  end

  test 'handles nil notifiable object gracefully' do
    message = NotificationComposer.generate('proof_approved', nil, @admin)
    assert_equal 'Proof approved for application #.', message
  end
end
