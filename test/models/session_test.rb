# frozen_string_literal: true

require 'test_helper'

class SessionTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent)
  end

  test 'a new session gets a 44-character base58 token during validation without a uniqueness query' do
    [nil, ''].each do |blank_token|
      session = @user.sessions.new(ip_address: '127.0.0.1', user_agent: 'Session test', session_token: blank_token)

      assert_no_queries { assert session.valid? }

      assert_match(/\A[1-9A-HJ-NP-Za-km-z]{44}\z/, session.session_token)
      token = session.session_token
      assert session.valid?
      assert_equal token, session.session_token
    end
  end

  test 'an explicitly supplied token survives validation and save' do
    session = @user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Session test', session_token: 'supplied-token')

    assert_equal 'supplied-token', session.reload.session_token
  end

  test 'validating a stored session neither replaces its token nor regenerates a cleared one' do
    session = create_session
    original = session.session_token

    assert session.valid?
    assert_equal original, session.session_token

    session.session_token = ''
    assert_not session.valid?
    assert_equal '', session.session_token
  end

  test 'a duplicate token is rejected by the unique index rather than by validation' do
    existing = create_session
    duplicate = @user.sessions.new(ip_address: '127.0.0.2', user_agent: 'Other', session_token: existing.session_token)

    assert duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { Session.transaction(requires_new: true) { duplicate.save! } }
  end

  test 'request metadata must be supplied and is not taken from Current' do
    Current.user_agent = 'Ambient agent'
    Current.ip_address = '203.0.113.9'

    session = @user.sessions.new

    assert_not session.valid?
    assert_includes session.errors.attribute_names, :user_agent
    assert_includes session.errors.attribute_names, :ip_address
  ensure
    Current.reset
  end

  test 'new sessions record activity and preserve the 24-hour absolute limit' do
    freeze_time do
      session = create_session

      assert_equal Time.current, session.last_active_at
      assert_equal 24.hours.from_now, session.expires_at
      assert_not session.expired?
    end
  end

  test 'idle expiry applies at the boundary even before absolute expiry' do
    freeze_time do
      session = create_session

      travel 30.minutes

      assert session.expired?
      assert_not session.record_activity!
      assert_equal 30.minutes.ago, session.reload.last_active_at
    end
  end

  test 'ordinary requests within a minute do not write activity' do
    freeze_time do
      session = create_session
      recorded_at = session.last_active_at

      travel 59.seconds

      assert_no_changes -> { session.reload.updated_at } do
        assert session.record_activity!
      end
      assert_equal recorded_at, session.reload.last_active_at
    end
  end

  test 'refreshing activity does not extend absolute expiry' do
    freeze_time do
      session = create_session
      expiry = session.expires_at

      travel 2.minutes
      assert session.record_activity!

      assert_equal Time.current, session.reload.last_active_at
      assert_equal expiry, session.expires_at
    end
  end

  test 'a stale session instance cannot revive an idle session' do
    freeze_time do
      session = create_session
      stale = Session.find(session.id)
      session.update!(last_active_at: 31.minutes.ago)

      travel 2.minutes

      assert_not stale.record_activity!
      assert_equal 33.minutes.ago, session.reload.last_active_at
    end
  end

  test 'stored sessions require activity' do
    session = create_session
    assert_raises ActiveRecord::NotNullViolation do
      Session.transaction(requires_new: true) { session.update_column(:last_active_at, nil) }
    end
  end

  test 'activity never moves backwards when another request has refreshed it' do
    freeze_time do
      session = create_session
      stale = Session.find(session.id)
      travel 2.minutes
      assert session.record_activity!
      assert stale.record_activity!
      assert_equal Time.current, session.reload.last_active_at
    end
  end

  test 'idle expiry is checked again after acquiring the activity lock' do
    freeze_time do
      session = create_session
      travel 2.minutes
      delay_lock(session, 28.minutes)

      assert_not session.record_activity!
      assert_equal 30.minutes.ago, session.reload.last_active_at
    end
  end

  test 'absolute expiry is checked again after acquiring the activity lock' do
    freeze_time do
      session = create_session
      session.update!(expires_at: 3.minutes.from_now)
      travel 2.minutes
      delay_lock(session, 2.minutes)

      assert_not session.record_activity!
      assert_equal 4.minutes.ago, session.reload.last_active_at
    end
  end

  private

  def create_session
    @user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Session test')
  end

  def delay_lock(session, duration)
    original_lock = session.method(:with_lock)
    advance_clock = -> { travel duration }
    session.define_singleton_method(:with_lock) do |&block|
      advance_clock.call
      original_lock.call(&block)
    end
  end
end
