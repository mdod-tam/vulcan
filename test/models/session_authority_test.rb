# frozen_string_literal: true

require 'test_helper'

class SessionAuthorityTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent)
    @record = @user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Authority test')
    @token = @record.session_token
  end

  test 'an existing session without full-authentication evidence is not recent' do
    with_user_lock do |user|
      assert_equal @record, @record.require_live!(token: @token, user: user)
      assert_raises(Session::AuthenticationRequired) do
        @record.require_recent_authentication!(token: @token, user: user)
      end
    end
  end

  test 'rotation preserves the database session and revokes the original bearer' do
    original_id = @record.id
    stale = Session.find(original_id)
    new_token = nil
    with_user_lock do |user|
      @record.require_live!(token: @token, user: user)
      @record.rotate_after_authentication!(user: user)
      new_token = @record.session_token
      assert_equal original_id, @record.id
      assert @record.freshly_authenticated?(user: user)
      assert_raises(Session::AuthenticationRequired) { stale.require_live!(token: @token, user: user) }
      assert_equal stale, stale.require_recent_authentication!(token: new_token, user: user)
    end
    assert_nil Session.for_token(@token).take
    assert_equal original_id, Session.for_token(new_token).pick(:id)
  end

  test 'freshness ends at five minutes and does not extend session absolute expiry' do
    freeze_time do
      expiry = @record.expires_at
      with_user_lock { |user| @record.rotate_after_authentication!(user: user) }
      token = @record.session_token
      travel 5.minutes
      with_user_lock do |user|
        assert_raises(Session::AuthenticationRequired) { @record.require_recent_authentication!(token: token, user: user) }
      end
      assert_equal expiry, @record.reload.expires_at
    end
  end

  test 'authority mutation invalidates freshness and pending MFA without logging every session out' do
    login_token = @user.generate_token_for(:two_factor_sign_in)
    token = nil
    with_user_lock do |user|
      @record.rotate_after_authentication!(user: user)
      token = @record.session_token
      user.advance_security_version!
      assert_equal @record, @record.require_live!(token: token, user: user)
      assert_raises(Session::AuthenticationRequired) { @record.require_recent_authentication!(token: token, user: user) }
    end
    assert_nil User.find_by_token_for(:two_factor_sign_in, login_token)
  end

  test 'a request that loaded a subsequently revoked session cannot authorize a write' do
    stale = Session.find(@record.id)
    @record.destroy!
    with_user_lock do |user|
      assert_raises(Session::AuthenticationRequired) { stale.require_live!(token: @token, user: user) }
    end
  end

  private

  def with_user_lock
    User.transaction do
      yield User.lock_for_merge_integrity!(@user).fetch(@user.id)
    end
  end
end
