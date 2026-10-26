# frozen_string_literal: true

module Baseline
  # Provisions the accounts a new environment needs. An existing eligible administrator is left exactly as it is,
  # and no other account is promoted, reactivated, or reused.
  module Accounts
    class Conflict < StandardError; end

    def self.provision_system_audit_actor!
      provision!('system audit', email: PublicAuditActor::SYSTEM_AUDIT_EMAIL, first_name: 'System', last_name: 'User',
                                 password: SecureRandom.hex(32), verified: true)
    end

    def self.provision_administrator!(email:, first_name:, last_name:, password:)
      provision!('administrator', email: email, first_name: first_name, last_name: last_name,
                                  password: password, email_verified: true)
    end

    # Queries the logical email and reads the stored identity without instantiating it, so a legacy STI type
    # or a database error fails closed instead of reading as "no such user".
    def self.provision!(label, email:, **attributes)
      email = User.normalize_email(email)
      identities = User.where(email: email).pluck(:id, :type, :merged_into_user_id, :status)
      return Users::Administrator.create!(email: email, **attributes) if identities.empty?

      id, type, merged_into_user_id, status = identities.sole
      eligible = type == 'Users::Administrator' && merged_into_user_id.nil? && [nil, 'active'].include?(status)
      raise Conflict, "The #{label} address belongs to an account that is not an active administrator; resolve it manually." unless eligible

      Users::Administrator.find(id)
    end
    private_class_method :provision!
  end
end
