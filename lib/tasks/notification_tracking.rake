# frozen_string_literal: true

namespace :notification_tracking do
  desc 'Report legacy notifications whose delivery was never tracked; no IDs or outcomes are invented'
  task :backfill, %i[fix_duplicates app_id] => :environment do |_task, args|
    scope = Notification.where(action: 'medical_certification_requested').where.missing(:email_delivery_attempts)
    scope = scope.where(notifiable_type: 'Application', notifiable_id: args[:app_id]) if args[:app_id].present?
    puts "#{scope.count} legacy requests have unknown delivery. No records changed."
  end

  desc 'Check up to 100 eligible email attempts within the finite polling budget'
  task check_all: :environment do
    EmailDelivery::PollJob.perform_later
    puts 'Queued a bounded delivery check.'
  end

  desc 'Report legacy notification tracking without changing request history'
  task :analyze, [:app_id] => :environment do |_task, args|
    Rake::Task['notification_tracking:backfill'].invoke(false, args[:app_id])
  end

  desc 'Retired: delivery records cannot establish duplicate requests'
  task :fix_duplicates, [:app_id] => :environment do
    puts 'No records changed. Review request history manually; matching request counts do not prove duplicate sends.'
  end
end
