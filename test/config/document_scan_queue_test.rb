# frozen_string_literal: true

require 'test_helper'

class DocumentScanQueueTest < ActiveSupport::TestCase
  test 'antivirus has its own worker and does not occupy the general worker queues' do
    assert_equal 'document_scans', DocumentScanJob.queue_name

    %w[development production].each do |environment|
      workers = queue_configuration.fetch(environment).fetch('workers')
      scanner, general = workers.partition { |worker| queue_names(worker).include?('document_scans') }
      assert_equal 1, scanner.size, environment
      assert_equal ['document_scans'], queue_names(scanner.sole)
      assert_equal 1, scanner.sole.fetch('threads')
      assert_not_empty general
      assert_not_includes general.flat_map { |worker| queue_names(worker) }, '*'

      served = workers.flat_map { |worker| queue_names(worker) }
      ApplicationJob.descendants.each do |job|
        assert_includes served, job.new.queue_name, "#{environment}: #{job.name}"
      end
      assert_includes served, ActionMailer::Base.deliver_later_queue_name || ActiveJob::Base.default_queue_name
      Rails.application.config.active_storage.queues.each_value do |queue|
        assert_includes served, queue.to_s if queue
      end
    end
  end

  private

  def queue_configuration
    YAML.safe_load(ERB.new(Rails.root.join('config/queue.yml').read).result, aliases: true)
  end

  def queue_names(worker)
    Array(worker.fetch('queues')).flat_map { |value| value.split(',').map(&:strip) }
  end
end
