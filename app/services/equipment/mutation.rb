# frozen_string_literal: true

module Equipment
  # Shared integrity rules for needs, ordering, and corrections.
  module Mutation
    module_function

    def authorize!(actor)
      raise Conflict, 'An active administrator is required.' unless actor&.admin? && actor.public_login_active?
    end

    def eligible!(application)
      return if application.equipment_procurement_eligible?

      raise Conflict, 'This application is not eligible for equipment purchasing.'
    end

    def eligible_for_funding!(application, source:)
      eligible!(application)
      if application.voucher_fulfillment? && source != 'icanconnect'
        raise Conflict, 'Use iCanConnect funding for direct equipment purchases on a MAT voucher application.'
      end

      Icanconnect::Funding.validate!(application, source: source)
    end

    def version!(record, expected)
      raise Conflict, 'Equipment changed. Refresh and review your selection.' unless expected.to_s == record.lock_version.to_s
    end

    def lock_applications!(ids)
      Application.where(id: ids).order(:id).lock.to_a
    end

    def assign_new_identifiers!(item, identifiers)
      %i[serial_number imei].each do |field|
        value = identifiers[field].to_s.strip.presence
        next unless value

        current = item.public_send(field)
        raise Conflict, 'A known physical identifier cannot be overwritten. Use a reviewed correction.' if current.present? && current != value

        item.public_send("#{field}=", value)
      end
    end

    def profile_versions(applications)
      applications.to_h { |application| [application.id.to_s, application.equipment_profile_version] }
    end

    def profile_versions!(applications, expected)
      observed = expected.to_h.stringify_keys.transform_values(&:to_s)
      return if observed == profile_versions(applications)

      raise Conflict, 'Application details changed. Refresh the shipping/setup review before continuing.'
    end

    def audit!(record, actor:, action:, changes:, operation_id: SecureRandom.uuid, **metadata)
      AuditEventService.log(action: action, actor: actor, auditable: record,
                            metadata: metadata.reverse_merge(reason: nil, application_ids: [])
                                              .merge(operation_id: operation_id, changes: changes))
    end
  end
end
