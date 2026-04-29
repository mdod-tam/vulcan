# frozen_string_literal: true

require 'application_system_test_case'

class AssignTrainerTest < ApplicationSystemTestCase
  setup do
    @admin = create(:admin)
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    @application = create(:application, :completed, application_date: 2.years.ago.to_date)
    @trainer = create(:user, :trainer, first_name: 'Jane', last_name: 'Trainer')

    # Set up policy to allow training sessions
    Policy.find_or_create_by(key: 'max_training_sessions').update(value: 2)

    # Sign in as admin via system test helper for reliability
    system_test_sign_in(@admin)
  end

  test 'admin can assign trainer to an approved application' do
    visit admin_application_path(@application)

    assert_text 'Application Details'
    assert_text 'Approved'
    assert_text 'Assign Trainer'
    within '[data-testid="trainer-assignment-form"]' do
      find('select[name="trainer_id"]').find('option', text: @trainer.full_name).select_option
      click_button 'Assign Trainer'
    end

    assert_equal @trainer.id, @application.reload.active_training_session&.trainer_id

    within '[data-testid="trainer-assignment-section"]' do
      assert_text 'Current Trainer'
      assert_text @trainer.full_name
    end
  end
end
