# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperGuardianQuickCreateServiceTest < ActiveSupport::TestCase
    class SimulatedPostAuditFailure < StandardError; end

    setup do
      @admin = create(:admin)
      @candidate = create(
        :constituent,
        first_name: 'Rollback',
        last_name: 'Guardian',
        date_of_birth: Date.new(1980, 1, 15)
      )
      @attrs = {
        first_name: 'Rollback',
        last_name: 'Guardian',
        date_of_birth: '1980-01-15',
        email: "guardian-audit-rollback-#{SecureRandom.hex(4)}@example.com",
        phone: "301#{format('%07d', SecureRandom.random_number(10_000_000))}",
        physical_address_1: '8 Rollback Way',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: 'email'
      }
    end

    test 'an exception after the confirmation event insert rolls back guardian and audit evidence' do
      review = PaperIdentityReview.new(
        constituent_params: @attrs,
        contact_flag_params: @attrs,
        admin: @admin,
        context: :guardian
      ).call
      assert review.needs_confirmation?

      service = PaperGuardianQuickCreateService.new(
        attrs: @attrs,
        request_params: @attrs,
        admin: @admin,
        submitted_token: review.token
      )
      original_log = AuditEventService.method(:log)
      event_inserted = false
      insert_then_fail = lambda do |**kwargs|
        event = original_log.call(**kwargs)
        event_inserted = event.persisted?
        raise SimulatedPostAuditFailure, 'failure after audit insert'
      end

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                            'Event.count', 'Notification.count'] do
        assert_raises SimulatedPostAuditFailure do
          AuditEventService.stub(:log, insert_then_fail) { service.call }
        end
      end
      assert event_inserted, 'the test must fail only after the real audit event insert'
      assert_nil User.find_by(email: @attrs.fetch(:email))
    end
  end
end
