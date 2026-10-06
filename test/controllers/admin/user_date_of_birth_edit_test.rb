# frozen_string_literal: true

require 'test_helper'

module Admin
  # Staff can correct a constituent's date of birth, which voucher verification and duplicate
  # detection depend on.
  class UserDateOfBirthEditTest < ActionDispatch::IntegrationTest
    setup do
      sign_in_for_integration_test(create(:admin))
      @constituent = create(:constituent, date_of_birth: Date.new(1980, 9, 10))
    end

    test 'the date of birth is required only once one is on file' do
      get edit_admin_user_path(@constituent)
      assert_select 'input[name="user[date_of_birth]"][value="09/10/1980"][required]'

      @constituent.update_column(:date_of_birth, nil)
      get edit_admin_user_path(@constituent)
      assert_select 'input[name="user[date_of_birth]"]:not([required])'
    end

    # So staff can add one before converting the user to a constituent.
    test 'the edit form offers a date of birth for other user types too' do
      trainer = create(:trainer)
      trainer.update_column(:date_of_birth, nil)

      get edit_admin_user_path(trainer)

      assert_select 'input[name="user[date_of_birth]"]:not([required])'
    end

    test 'a constituent without a date of birth can still save other edits' do
      @constituent.update_column(:date_of_birth, nil)

      patch admin_user_path(@constituent), params: { user: { first_name: 'Renamed', date_of_birth: '' } }

      assert_redirected_to admin_user_path(@constituent)
      assert_equal 'Renamed', @constituent.reload.first_name
    end

    test 'conversion to constituent requires a date of birth' do
      trainer = create(:trainer)
      trainer.update_column(:date_of_birth, nil)

      patch update_role_admin_user_path(trainer), params: { role: 'Constituent' }, as: :json
      assert_response :unprocessable_content
      assert_equal 'Users::Trainer', trainer.reload.type

      trainer.update!(date_of_birth: '09/10/1980')
      patch update_role_admin_user_path(trainer), params: { role: 'Constituent' }, as: :json
      assert_equal 'Users::Constituent', User.find(trainer.id).type
    end

    # Event metadata is not encrypted, so the change is recorded without its values.
    test 'a date of birth change is audited by name only' do
      patch admin_user_path(@constituent), params: { user: { date_of_birth: '10/09/1980' } }

      event = Event.where(auditable: @constituent).where('action LIKE ?', 'profile_%').order(:id).last
      assert_equal({ 'date_of_birth' => {} }, event.metadata['changes'])
      assert_not_includes event.metadata.to_json, '1980'
    end

    test 'an admin can correct a date of birth in any accepted spelling' do
      patch admin_user_path(@constituent), params: { user: { date_of_birth: '10-09-1980' } }

      assert_redirected_to admin_user_path(@constituent)
      assert_equal Date.new(1980, 10, 9), @constituent.reload.date_of_birth
    end

    test 'an admin can add a date of birth to a record that has none' do
      @constituent.update_column(:date_of_birth, nil)

      patch admin_user_path(@constituent), params: { user: { date_of_birth: '09/10/1980' } }

      assert_equal Date.new(1980, 9, 10), @constituent.reload.date_of_birth
    end

    test 'blank or unreadable input is refused and shown back' do
      patch admin_user_path(@constituent), params: { user: { date_of_birth: '9/9/26' } }

      assert_response :unprocessable_content
      assert_select 'input[name="user[date_of_birth]"][value="9/9/26"]'
      assert_equal Date.new(1980, 9, 10), @constituent.reload.date_of_birth

      patch admin_user_path(@constituent), params: { user: { date_of_birth: '' } }

      assert_response :unprocessable_content
      assert_equal Date.new(1980, 9, 10), @constituent.reload.date_of_birth
    end
  end
end
