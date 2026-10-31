# frozen_string_literal: true

require 'test_helper'

module SolidQueue
  # Solid Queue's own failure bookkeeping, run against db/queue_schema.rb, which must stay equal to the gem's schema.
  class FailedExecutionTest < ActiveSupport::TestCase
    class AlwaysFailsJob < ApplicationJob
      queue_as :failed_execution_test

      def perform
        raise 'worker failure'
      end
    end

    teardown do
      SolidQueue::Job.where(queue_name: AlwaysFailsJob.queue_name).destroy_all
      SolidQueue::Process.where(name: 'failed-execution-test').destroy_all
    end

    test 'a worker failure leaves one failed execution that retry puts back in the ready queue' do
      job = SolidQueue::Job.enqueue(AlwaysFailsJob.new)
      process = SolidQueue::Process.create!(kind: 'Worker', pid: ::Process.pid, name: 'failed-execution-test',
                                            last_heartbeat_at: Time.current)
      claimed = SolidQueue::ReadyExecution.claim(AlwaysFailsJob.queue_name, 1, process.id).sole

      assert_raises(RuntimeError) { claimed.perform }

      failed = job.reload.failed_execution
      assert_equal 'worker failure', failed.message
      assert_nil job.ready_execution

      failed.retry

      assert_nil job.reload.failed_execution
      assert_not_nil job.ready_execution
    end

    test 'failing the same job again updates its single failed execution' do
      job = SolidQueue::Job.enqueue(AlwaysFailsJob.new)

      job.failed_with(error_with('first failure'))
      job.failed_with(error_with('second failure'))

      assert_equal 1, SolidQueue::FailedExecution.where(job_id: job.id).count
      assert_equal 'second failure', job.reload.failed_execution.message
    end

    private

    def error_with(message)
      RuntimeError.new(message).tap { |error| error.set_backtrace(caller) }
    end
  end
end
