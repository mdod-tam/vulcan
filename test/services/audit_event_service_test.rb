# frozen_string_literal: true

require 'test_helper'

class AuditEventServiceTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @template = create(:email_template, :text)
  end

  test 'distinct operation ids log distinct events inside the dedup window' do
    log_toggle(enabled: false, operation_id: 'op-1')
    log_toggle(enabled: true, operation_id: 'op-2')
    log_toggle(enabled: false, operation_id: 'op-3')

    assert_equal 3, toggle_events.count
  end

  test 'a retried operation id is suppressed inside the dedup window' do
    log_toggle(enabled: false, operation_id: 'op-1')

    assert_nil log_toggle(enabled: false, operation_id: 'op-1')
    assert_equal 1, toggle_events.count
  end

  test 'events without an operation id keep the action fingerprint' do
    log_toggle(enabled: false)

    assert_nil log_toggle(enabled: true)
    assert_equal 1, toggle_events.count
  end

  test 'change fingerprints match caller hashes and persisted JSON metadata' do
    %w[profile_updated profile_updated_by_guardian profile_created_by_admin_via_paper
       alternate_contact_updated medical_provider_info_updated].each do |action|
      metadata = { changes: { first_name: { old: 'Before', new: 'After' } } }
      event = AuditEventService.log(action: action, actor: @admin, auditable: @template, metadata: metadata)

      assert_equal 'After', event.reload.metadata.dig('changes', 'first_name', 'new')
      assert_no_difference -> { Event.where(action: action, auditable: @template).count } do
        assert_nil AuditEventService.log(action: action, actor: @admin, auditable: @template, metadata: metadata)
        assert_nil AuditEventService.log(action: action, actor: @admin, auditable: @template,
                                         metadata: metadata.deep_stringify_keys)
      end

      changed_metadata = { changes: { first_name: { old: 'After', new: 'Later' } } }
      assert_difference -> { Event.where(action: action, auditable: @template).count }, 1 do
        AuditEventService.log(action: action, actor: @admin, auditable: @template, metadata: changed_metadata)
      end
    end
  end

  test 'change fingerprints preserve false through JSON persistence' do
    metadata = { changes: { hearing_disability: { old: true, new: false } } }
    event = AuditEventService.log(action: 'profile_updated', actor: @admin, auditable: @template, metadata: metadata)

    assert_equal false, event.reload.metadata.dig('changes', 'hearing_disability', 'new')
    assert_nil AuditEventService.log(action: 'profile_updated', actor: @admin, auditable: @template,
                                     metadata: metadata.deep_stringify_keys)

    assert_difference -> { Event.where(action: 'profile_updated', auditable: @template).count }, 1 do
      AuditEventService.log(action: 'profile_updated', actor: @admin, auditable: @template,
                            metadata: { changes: { hearing_disability: { old: false, new: nil } } })
    end
  end

  test 'proof review follow-up incidents distinguish reviews and suppress retries for the same review' do
    action = 'proof_review_follow_up_failed'
    metadata = { proof_review_id: 101, proof_type: 'income' }

    assert_difference -> { Event.where(action: action, auditable: @template).count }, 2 do
      first = AuditEventService.log(action: action, actor: @admin, auditable: @template, metadata: metadata)
      assert_equal 101, first.reload.metadata['proof_review_id']
      AuditEventService.log(action: action, actor: @admin, auditable: @template,
                            metadata: metadata.merge(proof_review_id: 102))
    end

    assert_no_difference -> { Event.where(action: action, auditable: @template).count } do
      assert_nil AuditEventService.log(action: action, actor: @admin, auditable: @template,
                                       metadata: metadata.deep_stringify_keys)
    end
  end

  test 'W9 decisions for successive documents retain separate audits at the same time and refuse stale decisions' do
    travel_to Time.zone.local(2026, 10, 9, 12) do
      %w[approved rejected].each do |status|
        vendor = create(:vendor, :with_w9)
        first_blob = vendor.w9_form.blob
        attributes = { status: status, reviewed_blob_id: first_blob.id,
                       rejection_reason_code: 'other', rejection_reason: 'Please correct the document.' }
        assert_predicate Vendors::ReviewW9.new(vendor: vendor, admin: @admin, attributes: attributes).call, :success?

        second_blob = Vendors::ReplaceW9.call(
          vendor: vendor, file: Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf')
        )
        assert_not_equal first_blob.id, second_blob.id
        second_review = Vendors::ReviewW9.new(
          vendor: vendor, admin: @admin, attributes: attributes.merge(reviewed_blob_id: second_blob.id)
        ).call
        assert_predicate second_review, :success?

        events = Event.where(auditable: vendor, action: "w9_#{status}")
        reviewed_documents = events.order(:id).pluck(:metadata).map { |metadata| metadata['reviewed_blob_id'] }
        assert_equal [first_blob.id, second_blob.id], reviewed_documents
        assert_equal [Time.current], events.distinct.pluck(:created_at)
        assert_equal 2, vendor.w9_reviews.count

        [first_blob, second_blob].each do |blob|
          assert_no_changes -> { [events.count, vendor.w9_reviews.count, vendor.reload.w9_status, vendor.w9_rejections_count] } do
            result = Vendors::ReviewW9.new(
              vendor: vendor, admin: @admin, attributes: attributes.merge(reviewed_blob_id: blob.id)
            ).call
            assert_predicate result, :failure?
          end
        end
      end
    end
  end

  private

  def log_toggle(enabled:, operation_id: nil)
    AuditEventService.log(
      action: 'email_template_toggled',
      actor: @admin,
      auditable: @template,
      metadata: { enabled: enabled, operation_id: operation_id }.compact
    )
  end

  def toggle_events
    Event.where(action: 'email_template_toggled', auditable: @template)
  end
end
