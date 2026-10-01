# frozen_string_literal: true

# Email delivery outcomes are attributed to the configured system audit account and never create
# one, so tests that assert those events provision it first.
module EmailDeliveryTestHelper
  def ensure_system_audit_actor!
    PublicAuditActor.system_audit_actor ||
      create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
  end
end

ActiveSupport.on_load(:active_support_test_case) { include EmailDeliveryTestHelper }
