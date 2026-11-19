# frozen_string_literal: true

module EquipmentProfileTestHelper
  def equipment_profile_versions(*applications)
    Equipment::Mutation.profile_versions(Application.where(id: applications.flatten.map(&:id)))
  end

  def equipment_bid_profile_versions(group)
    applications = group.active_lines.includes({ equipment_need: :application }, { equipment_item: :application }).filter_map(&:application)
    equipment_profile_versions(*applications)
  end
end

ActiveSupport.on_load(:active_support_test_case) { include EquipmentProfileTestHelper }
