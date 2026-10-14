# frozen_string_literal: true

namespace :equipment_needs do
  desc 'Initialize approved equipment purchasing needs from the latest completed report; requires an active admin ID'
  task :initialize, [:admin_id] => :environment do |_task, args|
    actor = User.find(args[:admin_id])
    Equipment::Mutation.authorize!(actor)
    initialized = 0
    skipped = 0
    Application.equipment_procurement_eligible.where(equipment_needs_initialized_at: nil).find_each do |application|
      application.with_lock do
        evaluation = application.evaluations.completed_sessions.by_report_submission.first
        if application.equipment_procurement_eligible? && evaluation && EquipmentNeeds::Writer.initialize_from!(evaluation, actor: actor)
          initialized += 1
        else
          skipped += 1
        end
      end
    end
    puts "Initialized #{initialized} applications; skipped #{skipped} without a completed report or with unmapped legacy fulfillment."
  end
end
