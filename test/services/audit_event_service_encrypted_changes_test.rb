# frozen_string_literal: true

require 'test_helper'

class AuditEventServiceEncryptedChangesTest < ActiveSupport::TestCase
  setup do
    @actor = create(:admin)
    @constituent = create(:constituent)
  end

  test 'personal changes store their masks directly in metadata without encrypted copies' do
    event = log(@constituent, changes: { email: { old: 'alice@example.com', new: 'bob@example.com' },
                                         first_name: { old: 'Alice', new: 'Bob' },
                                         date_of_birth: { old: '1980-09-10', new: '1981-10-09' } })

    changes = event.reload.metadata['changes']
    assert_equal({ 'old' => 'a***@e***.com', 'new' => 'b***@e***.com' }, changes['email'])
    assert_equal({ 'old' => 'A***', 'new' => 'B***' }, changes['first_name'])
    assert_equal({ 'old' => '[withheld]', 'new' => '[withheld]' }, changes['date_of_birth'])
    assert_equal changes, event.field_changes
    assert_nil event.change_values
    raw = Event.connection.select_one("SELECT metadata::text, change_values FROM events WHERE id = #{event.id}")
    assert_nil raw['change_values']
    %w[alice@example.com bob@example.com Alice Bob 1980-09-10 1981-10-09].each do |value|
      assert_not_includes raw.values.join, value
      assert_not_includes event.change_values.to_s, value
    end
  end

  test 'saved changes arrays and paper from-to hashes retain their shape' do
    event = log(create(:vendor), action: 'vendor_updated', changes: { business_tax_id: %w[123456789 987654321] })
    assert_equal ['***-**-6789', '***-**-4321'], event.metadata['changes']['business_tax_id']
    assert_nil event.change_values

    paper = log(@constituent, action: 'constituent_contact_updated', changes: { phone: { from: nil, to: '410-555-1234' } })
    assert_equal({ 'from' => nil, 'to' => '***-***-1234' }, paper.metadata['changes']['phone'])
    assert_equal [nil, '***-***-1234'], paper.field_change_pairs['phone']
    assert_nil paper.change_values
  end

  test 'device changes retain full encrypted operational history' do
    changes = { serial_number: %w[PRIVATE-SERIAL-A PRIVATE-SERIAL-B],
                serial_duplicate_reason: [nil, 'Reviewed PRIVATE-SERIAL-B'], notes: [nil, 'private note'] }
    event = log(create(:equipment_item), action: 'equipment_item_corrected', changes: changes)

    assert_equal({}, event.metadata.dig('changes', 'serial_number'))
    assert_equal({}, event.metadata.dig('changes', 'serial_duplicate_reason'))
    assert_equal [nil, '[withheld]'], event.metadata.dig('changes', 'notes')
    assert_equal changes.slice(:serial_number, :serial_duplicate_reason).deep_stringify_keys, JSON.parse(event.change_values)
    assert_equal %w[PRIVATE-SERIAL-A PRIVATE-SERIAL-B], event.field_changes['serial_number']
    assert_equal [nil, 'Reviewed PRIVATE-SERIAL-B'], event.field_changes['serial_duplicate_reason']
    raw = Event.connection.select_one("SELECT metadata::text, change_values FROM events WHERE id = #{event.id}")
    %w[PRIVATE-SERIAL-A PRIVATE-SERIAL-B].each { |value| assert_not_includes raw.values.join, value }
    assert_not_includes event.change_values, 'private note'
  end

  test 'contact extras and top-level provider destinations use the same policy' do
    event = AuditEventService.log(action: 'medical_provider_info_updated', actor: @actor, auditable: create(:application),
                                  metadata: { provider_email: 'doctor@example.test',
                                              changes: { alternate_contact_name: { old: 'Alice Smith', new: 'Bob Jones' } } })
    assert_equal 'd***@e***.test', event.metadata['provider_email']
    assert_equal({ 'old' => 'A*** S***', 'new' => 'B*** J***' }, event.field_changes['alternate_contact_name'])
  end

  test 'assignment names and free-text reasons are masked while identifiers and reason codes remain' do
    event = AuditEventService.log(action: 'note_assigned', actor: @actor, auditable: create(:application),
                                  metadata: { assigned_to_id: @actor.id, assigned_to_name: 'Alice Smith',
                                              completed_by_name: 'Bob Jones', rationale: 'Born 1980-09-10',
                                              rejection_reason: 'Address is 123 Private Lane',
                                              decline_reason: 'Email alice@example.com', rejection_reason_code: 'other' })

    assert_equal @actor.id, event.metadata['assigned_to_id']
    assert_equal 'A*** S***', event.metadata['assigned_to_name']
    assert_equal 'B*** J***', event.metadata['completed_by_name']
    %w[rationale rejection_reason decline_reason].each { |key| assert_equal '[withheld]', event.metadata[key] }
    assert_equal 'other', event.metadata['rejection_reason_code']
    %w[1980-09-10 Private alice@example.com].each { |value| assert_not_includes event.reload.metadata.to_json, value }
  end

  test 'nested metadata stores masks and preserves the exact actor and structural facts' do
    metadata = { candidates: [{ user_id: @constituent.id, role: 'applicant', email: 'alice@example.com',
                                details: { phone: '410-555-1234', date_of_birth: '1980-09-10' } }],
                 raw_token: { value: 'private-token' }, changes: { first_name: { old: 'Alice', new: 'Anne' } } }
    original = metadata.deep_dup
    event = AuditEventService.log(action: 'profile_updated', actor: @actor, auditable: @constituent, metadata: metadata)

    assert_equal @actor, event.reload.user
    assert_equal @actor.id, event.user_id
    assert_equal [{ 'user_id' => @constituent.id, 'role' => 'applicant', 'email' => 'a***@e***.com',
                    'details' => { 'phone' => '***-***-1234', 'date_of_birth' => '[withheld]' } }], event.metadata['candidates']
    assert_equal({ 'value' => '[withheld]' }, event.metadata['raw_token'])
    assert_equal({ 'first_name' => { 'old' => 'A***', 'new' => 'A***' } }, event.field_changes)
    assert_nil event.change_values
    assert_equal original, metadata
    raw = Event.connection.select_value("SELECT metadata::text FROM events WHERE id = #{event.id}")
    %w[alice@example.com 410-555-1234 1980-09-10 private-token Alice Anne].each { |value| assert_not_includes raw, value }
  end

  test 'distinct changes with identical masks and repeated transitions are retained' do
    freeze_time do
      %w[alice@example.com anne@example.com alice@example.com anne@example.com].each { |email| @constituent.update!(email: email) }
      events = Event.where(auditable: @constituent, action: 'profile_updated').where(created_at: Time.current)
      assert_equal 4, events.count
      assert_equal 4, Applications::EventDeduplicationService.new.deduplicate(events.to_a).size
    end
  end

  test 'a genuine operation id suppresses retries without hiding a later mutation' do
    metadata = { operation_id: 'change-1', changes: { first_name: { old: 'Alice', new: 'Anne' } } }
    assert AuditEventService.log(action: 'profile_updated', actor: @actor, auditable: @constituent, metadata: metadata)
    assert_nil AuditEventService.log(action: 'profile_updated', actor: @actor, auditable: @constituent, metadata: metadata)
    assert AuditEventService.log(action: 'profile_updated', actor: @actor, auditable: @constituent,
                                 metadata: metadata.merge(operation_id: 'change-2'))
  end

  test 'audit validation errors do not log submitted values or event attributes' do
    invalid_event = Event.new
    invalid_event.errors.add(:base, 'submitted secret 987654321 was rejected')
    Event.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(invalid_event))
    messages = []
    Rails.logger.stubs(:error).with do |message|
      messages << message
      true
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      log(@constituent, changes: { email: ['alice@example.com', 'bob@example.com'], password_digest: [nil, '987654321'] })
    end
    assert_includes messages.join, 'ActiveRecord::RecordInvalid'
    %w[alice@example.com bob@example.com 987654321].each { |value| assert_not_includes messages.join, value }
    assert_not_includes messages.join, 'Event attributes'
  end

  private

  def log(auditable, changes:, action: 'profile_updated')
    AuditEventService.log(action: action, actor: @actor, auditable: auditable, metadata: { changes: changes })
  end
end
