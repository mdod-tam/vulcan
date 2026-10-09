# frozen_string_literal: true

require 'test_helper'

class VendorsTaxRecordBackfillTest < ActiveSupport::TestCase
  test 'legacy tax values and audit copies encrypt without changing profile or historical state' do
    vendor = create(:vendor, :with_w9, business_tax_id: '123456789')
    ActiveRecord::Encryption.without_encryption { vendor.update_columns(business_tax_id: '123456789') }
    event = Event.create!(user: vendor, auditable: vendor, action: 'vendor_updated',
                          metadata: { changes: { business_tax_id: %w[111223333 123456789], phone: {} } },
                          change_values: { phone: %w[410-555-1000 410-555-1001] }.to_json)
    original_state = vendor.reload.attributes.slice('updated_at', 'w9_status', 'w9_rejections_count')
    original_event_time = event.created_at
    original_count = Event.count

    cursors = Vendors::TaxRecordBackfill.call(batch_size: 1)

    assert_operator cursors[:after_user_id], :>=, vendor.id
    assert_operator cursors[:after_event_id], :>=, event.id
    assert_equal '123456789', vendor.reload.business_tax_id
    assert vendor.encrypted_attribute?(:business_tax_id)
    assert_equal original_state, vendor.attributes.slice('updated_at', 'w9_status', 'w9_rejections_count')
    assert_equal original_count, Event.count
    assert_equal original_event_time, event.reload.created_at
    assert_equal %w[111223333 123456789], event.field_changes['business_tax_id']
    assert_equal %w[410-555-1000 410-555-1001], event.field_changes['phone']
    raw = Event.connection.select_one("SELECT metadata::text, change_values FROM events WHERE id = #{event.id}")
    %w[111223333 123456789].each { |tin| assert_not_includes raw.values.join, tin }

    encrypted_user = vendor.ciphertext_for(:business_tax_id)
    encrypted_event = event.ciphertext_for(:change_values)
    Vendors::TaxRecordBackfill.call(batch_size: 1)

    assert_equal encrypted_user, vendor.reload.ciphertext_for(:business_tax_id)
    assert_equal encrypted_event, event.reload.ciphertext_for(:change_values)
  end

  test 'backfill resumes independently after user and audit cursors' do
    skipped = create(:vendor)
    resumed = create(:vendor)
    [skipped, resumed].each do |vendor|
      ActiveRecord::Encryption.without_encryption { vendor.update_columns(business_tax_id: '123456789') }
    end
    first_event = legacy_event(skipped)
    second_event = legacy_event(resumed)
    progress = []

    Vendors::TaxRecordBackfill.call(after_user_id: skipped.id, after_event_id: first_event.id, batch_size: 1) do |cursors|
      progress << cursors
    end

    assert_not skipped.reload.encrypted_attribute?(:business_tax_id)
    assert resumed.reload.encrypted_attribute?(:business_tax_id)
    assert_equal %w[111223333 123456789], first_event.reload.metadata.dig('changes', 'business_tax_id')
    assert_equal({}, second_event.reload.metadata.dig('changes', 'business_tax_id'))
    assert_equal second_event.id, progress.last[:after_event_id]
  end

  private

  def legacy_event(vendor)
    Event.create!(user: vendor, auditable: vendor, action: 'vendor_updated',
                  metadata: { changes: { business_tax_id: %w[111223333 123456789] } })
  end
end
