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

  private

  def log(auditable, changes:, action: 'profile_updated')
    AuditEventService.log(action: action, actor: @actor, auditable: auditable, metadata: { changes: changes })
  end
end
