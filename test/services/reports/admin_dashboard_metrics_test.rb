# frozen_string_literal: true

require 'test_helper'

module Reports
  class AdminDashboardMetricsTest < ActiveSupport::TestCase
    setup do
      @cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(@cache)
    end

    test 'report data stays cached while application counts remain current' do
      create(:application, :in_progress)
      first = AdminDashboardMetrics.call
      assert @cache.exist?(AdminDashboardMetrics::CACHE_KEY)

      create(:application, :in_progress)
      assert_equal first[:open_applications_count] + 1, AdminDashboardMetrics.call[:open_applications_count]

      AdminDashboardMetrics.expire!
      assert_not @cache.exist?(AdminDashboardMetrics::CACHE_KEY)
      assert_equal first[:open_applications_count] + 1, AdminDashboardMetrics.call[:open_applications_count]
    end

    test 'the print queue and reassignment counts are read on every call' do
      AdminDashboardMetrics.call
      PrintQueueItem.stubs(:unreleased).returns(stub(count: 7))

      assert_equal 7, AdminDashboardMetrics.call[:print_queue_pending_count]
    end

    test 'waiting for documents is separate from documents already available for staff review' do
      before = AdminDashboardMetrics.call
      create(:application, status: :awaiting_proof)
      create(:application, status: :reminder_sent)
      create(:application, status: :awaiting_dcf, disability_certification_status: :requested)
      create(:application, status: :awaiting_dcf, disability_certification_status: :not_requested, document_signing_status: :signed)
      create(:application, status: :awaiting_dcf, disability_certification_status: :not_requested)
      create(:application, status: :in_progress, disability_certification_status: :received)
      create(:application, status: :in_progress, disability_certification_status: :received, document_signing_status: :signed)
      create(:application, status: :archived, disability_certification_status: :requested)

      counts = AdminDashboardMetrics.call

      assert_equal before[:active_awaiting_proofs_count] + 2, counts[:active_awaiting_proofs_count]
      assert_equal before[:active_awaiting_certifications_count] + 1, counts[:active_awaiting_certifications_count]
      assert_equal before[:active_cert_requests_needed_count] + 1, counts[:active_cert_requests_needed_count]
      assert_equal before[:active_disability_certs_to_review_count] + 3, counts[:active_disability_certs_to_review_count]
    end

    test 'equipment summary follows the pipeline after PO sending and shipment' do
      baseline = AdminDashboardMetrics.call
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                                      equipment_needs_initialized_at: Time.current)
      order = create(:purchase_order, sent_at: nil)
      items = create_list(:equipment_item, 2, application: application, purchase_order: order)
      before = AdminDashboardMetrics.call
      assert_equal baseline[:approved_stage_counts][:ready_to_send_po] + 1, before[:approved_stage_counts][:ready_to_send_po]

      order.update!(sent_at: Date.current)
      sent = AdminDashboardMetrics.call
      assert_equal baseline[:approved_stage_counts][:ready_to_send_po], sent[:approved_stage_counts][:ready_to_send_po]
      assert_equal baseline[:approved_stage_counts][:awaiting_shipment] + 1, sent[:approved_stage_counts][:awaiting_shipment]

      items.each { |item| item.update!(shipped_at: Date.current, tracking_number: 'DASHBOARD-SHIPMENT') }
      shipped = AdminDashboardMetrics.call
      assert_equal baseline[:approved_stage_counts][:shipment_recorded] + 1, shipped[:approved_stage_counts][:shipment_recorded]
      assert_equal application.reload.equipment_fulfillment_stage.stage,
                   Applications::ApprovedPipeline.new([application]).rows.sole.stage
    end

    test 'approved training count includes unassigned voucher requests and scheduled work once per application' do
      before = AdminDashboardMetrics.call[:approved_training_waiting_count]
      requested = create(:application, :approved, training_requested_at: 1.hour.ago, fulfillment_type: :voucher)
      scheduled = create(:application, :approved)
      create(:training_session, :scheduled, application: scheduled)
      create(:application, :in_progress, training_requested_at: 1.hour.ago)
      completed = create(:application, :approved, training_requested_at: 3.days.ago)
      create(:training_session, :completed, application: completed)

      assert_nil requested.assigned_trainer_id
      assert_equal before + 2, AdminDashboardMetrics.approved_training_waiting_count
      assert_equal before + 2, AdminDashboardMetrics.call[:approved_training_waiting_count]
      assert_equal 1, Application.with_pending_training_request.where(id: [requested.id, scheduled.id]).count

      create(:training_session, application: requested)
      assert_equal before + 2, AdminDashboardMetrics.approved_training_waiting_count
      assert_equal before + 2, AdminDashboardMetrics.call[:approved_training_waiting_count]
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
