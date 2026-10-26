# frozen_string_literal: true

require 'application_system_test_case'

class AssignTrainerTest < ApplicationSystemTestCase
  setup do
    @admin = create(:admin)
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    @application = create(:application, :completed, :with_all_proofs, application_date: 2.years.ago.to_date)
    @trainer = create(:user, :trainer, first_name: 'Jane', last_name: 'Trainer')

    Policy.find_or_create_by(key: 'max_training_sessions').update(value: 2)

    system_test_sign_in(@admin)
  end

  test 'admin can assign trainer to an approved application' do
    visit admin_application_path(@application)

    assert_text 'Application Details'
    assert_text 'Approved'
    assert_text 'Assign Trainer'
    within '[data-testid="trainer-assignment-form"]' do
      select "#{@trainer.full_name} (#{@trainer.email})", from: 'trainer_id'
      take_screenshot('admin-trainer-assignment-selected', html: true, full: true)
      click_button 'Assign Trainer'
    end

    within '[data-testid="trainer-assignment-section"]' do
      assert_text 'Current Trainer'
      assert_text @trainer.full_name
    end

    assert_equal @trainer.id, @application.reload.active_training_session&.trainer_id
  end
end
