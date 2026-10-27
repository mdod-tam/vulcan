# frozen_string_literal: true

require 'test_helper'

module Applications
  class CertificationEventsServiceTest < ActiveSupport::TestCase
    setup do
      @application = create(:application, status: :in_progress)
      @admin = create(:admin)
      @service = CertificationEventsService.new(@application)
    end

    test 'certification_events returns only certification-related events' do
      # Create a mix of certification and non-certification events using the existing admin user
      cert_notification = create(:notification,
                                 notifiable: @application,
                                 action: 'medical_certification_requested',
                                 actor: @admin,
                                 recipient: @application.user)

      # Create ApplicationStatusChange directly since there's no factory
      cert_status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'submitted',
        to_status: 'requested',
        metadata: { change_type: 'medical_certification' }
      )

      cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'medical_certification_approved',
        metadata: {}
      )

      non_cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'application_created',
        metadata: {}
      )

      # Stub the audit log builder so filtering is tested without deduplication.
      all_events = [cert_notification, cert_status_change, cert_event, non_cert_event]
      @service.instance_variable_get(:@audit_log_builder).stubs(:build_deduplicated_audit_logs).returns(all_events)

      result = @service.certification_events

      assert_includes result, cert_notification
      assert_includes result, cert_status_change
      assert_includes result, cert_event
      assert_not_includes result, non_cert_event
      assert_equal 3, result.size
    end

    test 'request_events returns only request-related certification events' do
      # Create a mix of request and other certification events using the existing admin user
      # Use different timestamps to avoid deduplication
      time_base = Time.current

      request_notification = create(:notification,
                                    notifiable: @application,
                                    action: 'medical_certification_requested',
                                    actor: @admin,
                                    recipient: @application.user)
      request_notification.update!(created_at: time_base - 2.minutes)

      approved_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'medical_certification_approved',
        metadata: {},
        created_at: time_base - 1.minute
      )

      request_status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'submitted',
        to_status: 'requested',
        metadata: { change_type: 'medical_certification' },
        created_at: time_base
      )

      all_events = [request_notification, approved_event, request_status_change]
      @service.instance_variable_get(:@audit_log_builder).stubs(:build_deduplicated_audit_logs).returns(all_events)

      result = @service.request_events

      assert_equal 2, result.size
      assert(result.all? { |r| r.is_a?(Hash) })

      # Verify hash structure expected by admin views
      result.each do |request_event|
        assert request_event.key?(:timestamp)
        assert request_event.key?(:actor_name)
        assert request_event.key?(:submission_method)
        assert request_event[:timestamp].is_a?(Time)
        assert_equal @admin.full_name, request_event[:actor_name]
      end

      assert_equal result, result.sort_by { |r| r[:timestamp] }.reverse
    end
  end
end
