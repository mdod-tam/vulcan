# frozen_string_literal: true

require 'test_helper'

class CleanupExpiredSessionsJobTest < ActiveSupport::TestCase
  test 'cleanup agrees with idle and absolute expiry and preserves refreshed sessions on repeat' do
    user = create(:constituent)
    at = Time.current.change(usec: 0)
    sessions = [
      { last_active_at: at - Session::IDLE_TIMEOUT + 1.minute, expires_at: at + 1.hour },
      { last_active_at: at - Session::IDLE_TIMEOUT, expires_at: at + 1.hour },
      { last_active_at: at, expires_at: at },
      { last_active_at: at, expires_at: at + 1.hour }
    ].map { |attributes| Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'cleanup test', **attributes) }
    missing_deadline = Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'missing deadline', last_active_at: at)
    missing_deadline.update_column(:expires_at, nil)
    sessions << missing_deadline
    travel_to(at) do
      expected = sessions.select { |session| session.expired?(at:) }.map(&:id).sort
      assert_equal expected, Session.expired_at(at).ids.sort
      2.times { CleanupExpiredSessionsJob.perform_now }
      assert_equal [sessions.first.id, sessions[3].id].sort, user.sessions.ids.sort
    end
  end
end
