# frozen_string_literal: true

require 'test_helper'
require 'fugit'

class RecurringConfigTest < ActiveSupport::TestCase
  RECURRING_TASKS = %w[
    poll_email_delivery
    cleanup_unattached_uploads
    generate_vendor_invoices
    check_voucher_expiration
    proof_attachment_metrics
    record_secure_form_expirations
    proof_consistency_check
    clear_solid_queue_finished_jobs
  ].freeze

  test 'renders every production recurring task at the top level with a parseable schedule' do
    FeatureFlag.stubs(:enabled?).returns(true)

    tasks = rendered_production_tasks

    assert_equal RECURRING_TASKS.sort, tasks.keys.sort
    tasks.each do |key, task|
      schedule = task.fetch('schedule')
      assert_not_nil Fugit.parse(schedule), "#{key} schedule does not parse: #{schedule.inspect}"
    end
  end

  test 'keeps the voucher task out of the production schedules when the flag is disabled' do
    FeatureFlag.stubs(:enabled?).returns(false)

    tasks = rendered_production_tasks

    assert_equal (RECURRING_TASKS - ['check_voucher_expiration']).sort, tasks.keys.sort
  end

  private

  def rendered_production_tasks
    config = YAML.safe_load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    config.fetch('production')
  end
end
