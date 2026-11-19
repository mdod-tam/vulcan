# frozen_string_literal: true

module Applications
  module EquipmentProfile
    extend ActiveSupport::Concern

    included do
      include EquipmentShipping

      normalizes :program_disability_groups, with: ->(value) { Array(value).compact_blank.uniq }
      validate :confirmed_program_groups_allowed
      validate :reserved_program_groups_retained
    end

    def equipment_profile_version
      updated_at.utc.iso8601(6)
    end

    def default_equipment_setup_group
      program_disability_groups.first if program_disability_groups.one?
    end

    def update_equipment_profile!(attributes, actor:, shipping_confirmed: false, **metadata)
      profile = attributes.to_h.stringify_keys
      with_lock do
        if shipping_confirmed && EquipmentShipping::REQUIRED_FIELDS.any? { |field| profile[field].blank? }
          errors.add(:base, 'Complete the confirmed shipping destination, including city, state and ZIP code.')
          raise ActiveRecord::RecordInvalid, self
        end

        update!(profile)
        changes = previous_changes.except('updated_at', 'lock_version')
        Equipment::Mutation.audit!(self, actor: actor, action: 'equipment_profile_updated', changes: changes, **metadata) if changes.any?
      end
      self
    end

    def suggested_shipping_snapshot
      return shipping_snapshot unless shipping_snapshot.values.all?(&:blank?)

      owner = Applications::ContactContext.new(application: self).address_owner
      {
        'shipping_care_of' => owner.id == user_id ? nil : owner.full_name,
        'shipping_address_1' => owner.physical_address_1, 'shipping_address_2' => owner.physical_address_2,
        'shipping_city' => owner.city, 'shipping_state' => owner.state, 'shipping_zip_code' => owner.zip_code
      }
    end

    private

    def reserved_program_groups_retained
      return unless persisted? && will_save_change_to_program_disability_groups?

      removed = program_disability_groups_in_database - program_disability_groups
      return if removed.empty?

      reserved = BidGroupLine.reserved.left_joins(:equipment_need, :equipment_item)
                             .where(equipment_needs: { application_id: id, disability_setup_group: removed })
                             .or(BidGroupLine.reserved.left_joins(:equipment_need, :equipment_item)
                                             .where(equipment_items: { application_id: id, disability_setup_group: removed }))
      errors.add(:program_disability_groups, 'amend the active bid before removing its setup group') if reserved.exists?
    end

    def confirmed_program_groups_allowed
      return if (program_disability_groups - Product::PROGRAM_GROUPS.keys).empty?

      errors.add(:program_disability_groups, 'contains an unknown program group')
    end
  end
end
