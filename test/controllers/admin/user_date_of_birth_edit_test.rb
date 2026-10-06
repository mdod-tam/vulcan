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

    test 'the edit form shows the date of birth for a constituent only' do
      get edit_admin_user_path(@constituent)
      assert_select 'input[name="user[date_of_birth]"][value="09/10/1980"][required]'

      get edit_admin_user_path(create(:vendor, :approved))
      assert_select 'input[name="user[date_of_birth]"]', count: 0
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
