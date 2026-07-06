# frozen_string_literal: true

require 'test_helper'

class PublicAuditActorTest < ActiveSupport::TestCase
  test 'returns configured system audit actor without creating system user' do
    admin = create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)

    User.expects(:system_user).never

    assert_equal admin, PublicAuditActor.system_audit_actor
  end

  test 'returns nil when configured system audit actor is absent' do
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).delete_all
    create(:admin, email: 'other-admin@example.com')

    User.expects(:system_user).never

    assert_nil PublicAuditActor.system_audit_actor
  end

  test 'log_audit skips event when configured system audit actor is absent' do
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).delete_all

    assert_no_difference 'Event.count' do
      assert_nil PublicAuditActor.log_audit(
        action: 'auth_rate_limit_exceeded',
        metadata: { scope: 'ip' }
      )
    end
  end

  test 'log_audit attributes to configured system audit actor when present' do
    admin = create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)

    assert_difference 'Event.count', 1 do
      event = PublicAuditActor.log_audit(
        action: 'auth_rate_limit_exceeded',
        metadata: { scope: 'ip' }
      )

      assert_equal admin, event.user
      assert_equal PublicAuditActor::PUBLIC_AUDIT_ACTOR_METADATA, event.metadata['public_audit_actor']
      assert_equal 'ip', event.metadata['scope']
    end
  end
end
