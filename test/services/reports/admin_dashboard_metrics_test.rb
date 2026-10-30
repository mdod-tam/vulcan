# frozen_string_literal: true

require 'test_helper'

module Reports
  class AdminDashboardMetricsTest < ActiveSupport::TestCase
    setup do
      @cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(@cache)
    end

    test 'the heavy counts are cached under one key until expire! clears it' do
      create(:application, :in_progress)
      first = AdminDashboardMetrics.call
      assert @cache.exist?(AdminDashboardMetrics::CACHE_KEY)

      create(:application, :in_progress)
      assert_equal first[:open_applications_count], AdminDashboardMetrics.call[:open_applications_count]

      AdminDashboardMetrics.expire!
      assert_not @cache.exist?(AdminDashboardMetrics::CACHE_KEY)
      assert_equal first[:open_applications_count] + 1, AdminDashboardMetrics.call[:open_applications_count]
    end

    test 'the print queue and reassignment counts are read on every call' do
      AdminDashboardMetrics.call
      PrintQueueItem.stubs(:unreleased).returns(stub(count: 7))

      assert_equal 7, AdminDashboardMetrics.call[:print_queue_pending_count]
    end

    test 'expire! does not raise when the cache cannot delete' do
      @cache.stubs(:delete).raises(StandardError, 'cache down')

      assert_nothing_raised { AdminDashboardMetrics.expire! }
    end

    test 'a successful trainer assignment expires the cached counts' do
      Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
      Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
      application = create(:application, status: :approved, application_date: 2.years.ago.to_date)
      AdminDashboardMetrics.call
      assert @cache.exist?(AdminDashboardMetrics::CACHE_KEY)

      result = Applications::TrainerAssignment.assign(application, create(:trainer), actor: create(:admin))

      assert_predicate result, :success?
      assert_not @cache.exist?(AdminDashboardMetrics::CACHE_KEY)
    end

    test 'a refused trainer assignment leaves the cached counts alone' do
      application = create(:application, status: :approved, application_date: 2.years.ago.to_date)
      AdminDashboardMetrics.call

      result = Applications::TrainerAssignment.assign(application, nil, actor: create(:admin))

      assert_predicate result, :failure?
      assert @cache.exist?(AdminDashboardMetrics::CACHE_KEY)
    end
  end
end
