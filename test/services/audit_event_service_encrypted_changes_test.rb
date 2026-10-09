# frozen_string_literal: true

require 'test_helper'

# Event metadata is plain JSON. Values of fields the audited record encrypts must not land there.
class AuditEventServiceEncryptedChangesTest < ActiveSupport::TestCase
  setup do
    @actor = create(:admin)
    @constituent = create(:constituent)
  end

  test 'encrypted fields keep their names in metadata and their values in change_values' do
    event = log(@constituent, changes: { 'email' => { 'old' => 'a@example.com', 'new' => 'b@example.com' },
                                         'first_name' => { 'old' => 'Ann', 'new' => 'Anne' } })

    assert_equal({ 'email' => {}, 'first_name' => { 'old' => 'Ann', 'new' => 'Anne' } }, event.metadata['changes'])
    assert_equal({ 'old' => 'a@example.com', 'new' => 'b@example.com' }, event.field_changes['email'])
    assert_equal({ 'old' => 'Ann', 'new' => 'Anne' }, event.field_changes['first_name'])

    raw = Event.connection.select_one("SELECT metadata::text, change_values FROM events WHERE id = #{event.id}")
    assert_not_includes raw.values.join, 'example.com'
  end

  # Admin vendor edits log saved_changes, which use [old, new] arrays and symbol keys.
  test 'any change shape is protected and restored as given' do
    event = log(create(:vendor, :approved), action: 'vendor_updated', changes: { phone: %w[555-000-0001 555-000-0002] })

    assert_equal({ 'phone' => {} }, event.metadata['changes'])
    assert_equal %w[555-000-0001 555-000-0002], event.field_changes['phone']
  end

  test 'vendor tax changes are encrypted in audit storage' do
    event = log(create(:vendor), action: 'vendor_updated', changes: { business_tax_id: %w[123456789 987654321] })

    assert_equal({}, event.metadata['changes']['business_tax_id'])
    assert_equal %w[123456789 987654321], event.reload.field_changes['business_tax_id']
    raw = Event.connection.select_one("SELECT metadata::text, change_values FROM events WHERE id = #{event.id}")
    %w[123456789 987654321].each { |tin| assert_not_includes raw.values.join, tin }
  end

  test 'an audit validation error does not log submitted tax values or event attributes' do
    vendor = create(:vendor, business_tax_id: '123456789')
    invalid_event = Event.new
    invalid_event.errors.add(:base, 'submitted tax value 987654321 was rejected')
    Event.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(invalid_event))
    messages = []
    Rails.logger.stubs(:error).with do |message|
      messages << message
      true
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      log(vendor, action: 'vendor_updated', changes: { business_tax_id: %w[123456789 987654321] })
    end

    assert_includes messages.join, 'ActiveRecord::RecordInvalid'
    assert_not_includes messages.join, '123456789'
    assert_not_includes messages.join, '987654321'
    assert_not_includes messages.join, 'Event attributes'
  end

  test 'records without encrypted fields are stored as given' do
    application = create(:application)
    event = log(application, changes: { 'alternate_contact_name' => { 'old' => 'A', 'new' => 'B' } })

    assert_nil event.change_values
    assert_equal({ 'alternate_contact_name' => { 'old' => 'A', 'new' => 'B' } }, event.metadata['changes'])
  end

  test 'a repeat of the same encrypted change within the window is still suppressed' do
    changes = { 'phone' => { 'old' => '555-000-0001', 'new' => '555-000-0002' } }
    log(@constituent, changes: changes)

    assert_nil log(@constituent, changes: changes)
    assert log(@constituent, changes: { 'phone' => { 'old' => '555-000-0002', 'new' => '555-000-0003' } })
  end

  test 'separate vendor edits within the deduplication window retain separate encrypted tax history' do
    vendor = create(:vendor)
    changes = { business_tax_id: %w[123456789 987654321] }

    assert log(vendor, action: 'vendor_updated', changes: changes)
    assert_nil log(vendor, action: 'vendor_updated', changes: changes)
    event = log(vendor, action: 'vendor_updated', changes: { business_tax_id: %w[987654321 111223333] })

    assert event
    assert_equal %w[987654321 111223333], event.field_changes['business_tax_id']
  end

  test 'an unreadable change_values cell falls back without breaking reads' do
    event = log(@constituent, changes: { 'email' => { 'old' => 'a@example.com', 'new' => 'b@example.com' } })
    Event.connection.execute("UPDATE events SET change_values = 'not encrypted' WHERE id = #{event.id}")

    assert_equal({ 'email' => {} }, event.reload.field_changes)
  end

  private

  def log(auditable, changes:, action: 'profile_updated')
    AuditEventService.log(action: action, actor: @actor, auditable: auditable, metadata: { changes: changes })
  end
end
