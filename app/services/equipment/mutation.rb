# frozen_string_literal: true

module Equipment
  # Shared integrity rules for needs, ordering, and corrections.
  module Mutation
    module_function

    def authorize!(actor)
      raise Conflict, 'An active administrator is required.' unless actor&.admin? && actor.public_login_active?
    end

    def eligible!(application)
      raise Conflict, 'Only approved equipment applications can receive new purchasing assignments.' unless application.equipment_procurement_eligible?
    end

    def version!(record, expected)
      raise Conflict, 'Equipment changed. Refresh and review your selection.' unless expected.to_s == record.lock_version.to_s
    end

    def lock_applications!(ids)
      Application.where(id: ids).order(:id).lock.to_a
    end

    def audit!(record, actor:, action:, changes:, **metadata)
      AuditEventService.log(action: action, actor: actor, auditable: record,
                            metadata: metadata.reverse_merge(reason: nil, application_ids: [])
                                              .merge(operation_id: SecureRandom.uuid, changes: changes))
    end
  end
end
