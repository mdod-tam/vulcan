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

  test 'Escape does not dismiss the reassignment dialog while its request is pending' do
    create(:user, :trainer, first_name: 'Sam', last_name: 'Replacement')
    @application.update!(assigned_trainer: @trainer)
    create(:training_session, :scheduled, application: @application, trainer: @trainer)
    dialog = '#trainer-reassign-confirm-dialog'

    visit admin_application_path(@application)
    click_button 'Reassign Trainer'
    assert_selector "#{dialog}[open]"

    # Turbo marks the dialog busy from the moment the form submits until the response arrives.
    page.execute_script("document.querySelector('#{dialog}').dataset.busy = 'true'")
    find("#{dialog} select").send_keys(:escape)
    assert_selector "#{dialog}[open]"

    page.execute_script("delete document.querySelector('#{dialog}').dataset.busy")
    find("#{dialog} select").send_keys(:escape)
    assert_no_selector "#{dialog}[open]"
  end
end
