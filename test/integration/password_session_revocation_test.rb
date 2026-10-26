# frozen_string_literal: true

require 'test_helper'

class PasswordSessionRevocationTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @user = create(:constituent)
  end

  teardown { Current.reset }

  test 'a signed-in password change rotates this browser and revokes other existing sessions' do
    owner = signed_in_browser(@user)
    other_browser = signed_in_browser(@user)
    unrelated = signed_in_browser(create(:constituent))
    previous_session_ids = @user.sessions.pluck(:id)
    old_cookie = owner.cookies[:session_token]

    owner.patch password_path, params: valid_password_change

    assert_equal constituent_portal_dashboard_url, owner.response.location
    assert_empty Session.where(id: previous_session_ids)
    assert_equal 1, @user.sessions.reload.count
    assert_not_equal old_cookie, owner.cookies[:session_token]
    owner.get edit_profile_path
    assert_equal 200, owner.response.status
    other_browser.get edit_profile_path
    assert_equal sign_in_url, other_browser.response.location
    unrelated.get edit_profile_path
    assert_equal 200, unrelated.response.status
  end

  test 'a reset link revokes every existing session and clears the resetting browser authentication' do
    owner = signed_in_browser(@user)
    other_browser = signed_in_browser(@user)
    token = @user.generate_token_for(:password_reset)

    owner.patch password_path, params: valid_password_change.except(:password_challenge).merge(token: token)

    assert_equal sign_in_url, owner.response.location
    assert_empty @user.sessions.reload
    assert owner.cookies[:session_token].blank?
    assert_nil User.find_by_token_for(:password_reset, token)
    [owner, other_browser].each do |browser|
      browser.get edit_profile_path
      assert_equal sign_in_url, browser.response.location
    end
  end

  test 'a failed password change leaves all existing browsers signed in' do
    owner = signed_in_browser(@user)
    other_browser = signed_in_browser(@user)
    session_ids = @user.sessions.pluck(:id).sort
    old_cookie = owner.cookies[:session_token]

    owner.patch password_path, params: valid_password_change.merge(password_challenge: 'incorrect')

    assert_equal 422, owner.response.status
    assert_equal session_ids, @user.sessions.reload.order(:id).pluck(:id)
    assert_equal old_cookie, owner.cookies[:session_token]
    [owner, other_browser].each do |browser|
      browser.get edit_profile_path
      assert_equal 200, browser.response.status
    end
  end

  test 'a failed replacement session does not revive old sessions or misreport the committed password change' do
    owner = signed_in_browser(@user)
    old_session_ids = @user.sessions.pluck(:id)
    PasswordsController.any_instance.stubs(:_create_and_set_session_cookie).returns(nil)

    owner.patch password_path, params: valid_password_change

    assert_equal sign_in_url, owner.response.location
    assert owner.cookies[:session_token].blank?
    assert_empty Session.where(id: old_session_ids)
    assert @user.reload.authenticate('ChangedPassword123!')
    owner.follow_redirect!
    assert_includes owner.response.body, 'Password successfully updated.'
  end

  private

  def signed_in_browser(user)
    open_session do |browser|
      browser.post sign_in_path, params: { email: user.email, password: 'password1234' }
      assert_equal constituent_portal_dashboard_url, browser.response.location
      assert browser.cookies[:session_token].present?
    end
  end

  def valid_password_change
    { password_challenge: 'password1234', password: 'ChangedPassword123!', password_confirmation: 'ChangedPassword123!' }
  end
end
