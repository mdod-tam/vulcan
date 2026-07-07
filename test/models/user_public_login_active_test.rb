# frozen_string_literal: true

require 'test_helper'

class UserPublicLoginActiveTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent, email: "active-#{SecureRandom.hex(3)}@example.com")
  end

  test 'active and legacy-null status are treated as login-active' do
    assert @user.public_login_active?

    @user.update_column(:status, nil)
    assert @user.reload.public_login_active?, 'legacy NULL status is active'
  end

  test 'inactive, suspended, and merged records are not login-active' do
    @user.update!(status: :inactive)
    assert_not @user.public_login_active?

    @user.update!(status: :active)
    @user.update!(status: :suspended)
    assert_not @user.public_login_active?

    canonical = create(:constituent)
    @user.update!(status: :active, merged_into_user: canonical, merged_at: Time.current)
    assert_not @user.public_login_active?
  end

  test 'find_by_login_identifier excludes non-login-active records' do
    assert_equal @user, User.find_by_login_identifier(@user.email)

    @user.update!(status: :inactive)
    assert_nil User.find_by_login_identifier(@user.email)
  end

  test 'merged record cannot be found by login identifier' do
    canonical = create(:constituent)
    @user.update!(merged_into_user: canonical, merged_at: Time.current)
    assert_nil User.find_by_login_identifier(@user.email)
  end
end
