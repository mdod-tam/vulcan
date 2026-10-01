# frozen_string_literal: true

# These tasks attribute their changes to the configured system audit account; they never create one.
def email_delivery_task_actor
  PublicAuditActor.system_audit_actor ||
    abort("Configure the system administrator (#{PublicAuditActor::SYSTEM_AUDIT_EMAIL}) before running this task.")
end

namespace :email_delivery do
  desc 'Read-only: list template pairs whose English and Spanish settings disagree and which locales would stop'
  task template_pair_report: :environment do
    puts EmailDelivery::PairReconciliation.report
  end

  desc 'Turn off every template pair whose English and Spanish settings disagree (run template_pair_report first)'
  task reconcile_template_pairs: :environment do
    puts EmailDelivery::PairReconciliation.report
    results = EmailDelivery::PairReconciliation.apply!(actor: email_delivery_task_actor)
    puts "#{results.count(&:changed?)} template pairs turned off."
  end

  desc 'Read-only: count mail jobs queued before the email controls existed'
  task legacy_mail_job_report: :environment do
    puts EmailDelivery::LegacyMailJobs.report
  end

  desc 'Remove mail jobs queued before the email controls existed (run with workers stopped)'
  task remove_legacy_mail_jobs: :environment do
    puts EmailDelivery::LegacyMailJobs.report
    puts "#{EmailDelivery::LegacyMailJobs.remove!(actor: email_delivery_task_actor)} legacy mail jobs removed."
  end

  desc 'Show All, channel and category communication controls'
  task controls: :environment do
    FeatureFlag.where(name: EmailDelivery::CONTROL_NAMES).order(:name).each do |control|
      puts "#{control.name.ljust(40)} #{control.enabled ? 'on' : 'off'} (generation #{control.delivery_generation})"
    end
  end

  desc 'Turn all email off or on during a release (usage: email_delivery:set_global[off] or [on])'
  task :set_global, [:state] => :environment do |_task, args|
    abort 'Usage: email_delivery:set_global[off] or email_delivery:set_global[on]' unless %w[on off].include?(args[:state])

    result = EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: args[:state] == 'on',
                                              actor: email_delivery_task_actor, operation_id: "rake-set-global:#{SecureRandom.uuid}")
    puts "All email is #{result.control.enabled ? 'on' : 'off'} (#{result.status})."
  end
  desc 'Turn every outgoing channel off or on (usage: email_delivery:set_all[off] or [on])'
  task :set_all, [:state] => :environment do |_task, args|
    abort 'Usage: email_delivery:set_all[off] or email_delivery:set_all[on]' unless %w[on off].include?(args[:state])

    result = EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: args[:state] == 'on',
                                              actor: email_delivery_task_actor, operation_id: "rake-set-all:#{SecureRandom.uuid}")
    puts "All outgoing communications: #{result.control.enabled ? 'on' : 'off'} (#{result.status})."
  end

  desc 'Read-only: inventory pending print items lacking current authorization'
  task legacy_letter_report: :environment do
    scope = PrintQueueItem.unreleased.where("delivery_context IS NULL OR delivery_context->>'version' IS DISTINCT FROM ?", EmailDelivery::Policy::CONTEXT_VERSION.to_s)
    puts "#{scope.count} unreleased legacy letters require cancellation and deliberate reissue."
    scope.find_each { |item| puts "  Letter ##{item.id}: #{item.letter_type}" }
  end

  desc 'Cancel ineligible unreleased letters, including legacy items; never reauthorize or replay them'
  task reconcile_letters: :environment do
    email_delivery_task_actor
    Letters::Delivery.reconcile_pending!
    puts "#{PrintQueueItem.unreleased.count} letters remain awaiting release."
  end
end
