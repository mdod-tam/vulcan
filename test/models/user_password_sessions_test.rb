# frozen_string_literal: true

require 'test_helper'

class UserPasswordSessionsTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent)
    @sessions = 2.times.map { @user.sessions.create!(user_agent: 'Password security test', ip_address: '127.0.0.1') }
  end

  test 'a changed password digest revokes stored sessions even when the association was already loaded' do
    @user.sessions.load
    later_session = Session.create!(user: @user, user_agent: 'Another browser', ip_address: '127.0.0.2')
    unrelated = create(:constituent).sessions.create!(user_agent: 'Unrelated browser', ip_address: '127.0.0.3')

    @user.update!(password: 'ChangedPassword123!', password_confirmation: 'ChangedPassword123!')

    assert_empty Session.where(id: [*@sessions.map(&:id), later_session.id])
    assert Session.exists?(unrelated.id)
    assert @user.reload.authenticate('ChangedPassword123!')
  end

  test 'validation failure leaves the password and stored sessions intact' do
    original_digest = @user.password_digest

    assert_not @user.update(password: 'short', password_confirmation: 'short')

    assert_equal original_digest, @user.reload.password_digest
    assert_equal @sessions.map(&:id).sort, @user.sessions.order(:id).pluck(:id)
  end

  test 'a rolled back password change restores the password and stored sessions together' do
    original_digest = @user.password_digest

    User.transaction do
      @user.update!(password: 'ChangedPassword123!', password_confirmation: 'ChangedPassword123!')
      assert_empty Session.where(id: @sessions.map(&:id))
      raise ActiveRecord::Rollback
    end

    assert_equal original_digest, @user.reload.password_digest
    assert_equal @sessions.map(&:id).sort, @user.sessions.order(:id).pluck(:id)
  end

  test 'an ordinary profile change keeps stored sessions' do
    @user.update!(first_name: 'Updated')

    assert_equal @sessions.map(&:id).sort, @user.sessions.order(:id).pluck(:id)
  end
end
