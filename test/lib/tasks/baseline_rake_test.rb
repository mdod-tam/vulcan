# frozen_string_literal: true

require 'test_helper'
require 'rake'

# Each named task reapplies its baseline every time it runs, including when it runs twice in one process.
class BaselineRakeTest < ActiveSupport::TestCase
  setup do
    Rake::Task.define_task(:environment)
    load Rails.root.join('lib/tasks/baseline.rake') unless Rake::Task.task_defined?('db:seed_policies')
    ensure_system_audit_actor!
  end

  test 'seed_policies resets edited policies on each run' do
    2.times do |round|
      Policy.find_by!(key: 'max_proof_rejections').update_columns(value: 5 + round)
      run_task('db:seed_policies')
      assert_equal 3, Policy.get('max_proof_rejections')
    end
  end

  test 'seed_feature_flags resets flags and controls on each run' do
    2.times do
      FeatureFlag.find_by!(name: 'vouchers_enabled').update_columns(enabled: true)
      FeatureFlag.find_by!(name: 'email.category.vendor').update_columns(enabled: false)
      run_task('db:seed_feature_flags')
      assert_not FeatureFlag.enabled?(:vouchers_enabled)
      assert FeatureFlag.enabled?('email.category.vendor')
    end
  end

  test 'seed_rejection_reasons resets edited bodies on each run' do
    expected = Baseline::RejectionReasons::DEFINITIONS.first[:en_body]
    2.times do
      RejectionReason.find_by!(Baseline::RejectionReasons::DEFINITIONS.first.slice(:code, :proof_type).merge(locale: 'en'))
                     .update_columns(body: 'Edited')
      run_task('db:seed_rejection_reasons')
      assert_includes RejectionReason.pluck(:body), expected
      assert_not_includes RejectionReason.pluck(:body), 'Edited'
    end
  end

  test 'seed_manual_email_templates replaces every template with new ids on each run' do
    2.times do
      previous_ids = EmailTemplate.pluck(:id)
      EmailTemplate.first.update_columns(body: 'Edited copy')
      run_task('db:seed_manual_email_templates')
      assert_equal EmailTemplates::Catalog.files.size, EmailTemplate.count
      assert_empty previous_ids & EmailTemplate.pluck(:id)
      assert_not_includes EmailTemplate.pluck(:body), 'Edited copy'
    end
  end

  private

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    capture_io { task.invoke }
  end
end
