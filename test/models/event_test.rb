# frozen_string_literal: true

require 'test_helper'

class EventTest < ActiveSupport::TestCase
  setup do
    @actor = create(:admin)
  end

  test 'metadata defaults to an object and rejects non-object values without masking false or null' do
    event = Event.new(user: @actor, action: 'test_event')
    assert_equal({}, event.metadata)
    assert event.valid?

    [nil, false, true, [], 1, 'invalid'].each do |value|
      event.metadata = value
      assert_not event.valid?, "Accepted metadata #{value.inspect}"
      assert_includes event.errors[:metadata], 'must be a JSON object'
    end
  end

  test 'the database rejects non-object JSON when model validation is bypassed' do
    connection = Event.connection
    [nil, false, true, [], 1, 'invalid'].each do |value|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        Event.transaction(requires_new: true) do
          connection.execute(<<~SQL.squish)
            INSERT INTO events (user_id, action, metadata, created_at, updated_at)
            VALUES (#{@actor.id}, 'test_event', #{connection.quote(value.to_json)}::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          SQL
        end
      end
      assert_instance_of PG::CheckViolation, error.cause
      assert_includes error.message, 'events_metadata_object'
    end
  end

  test 'optional metadata stays flexible while changes must support field history readers' do
    event = Event.new(user: @actor, action: 'new_event_action', metadata: { extra: ['context'], changes: nil })
    assert event.valid?
    assert_equal({}, event.field_changes)

    event.metadata = { changes: { email: { old: nil, new: false }, status: %w[old new] }, extra: { future_key: true } }
    event.save!
    assert_equal [nil, false], event.reload.field_change_pairs['email']
    assert_equal %w[old new], event.field_change_pairs['status']

    [false, [], 'invalid'].each do |value|
      event.metadata = { changes: value }
      assert_not event.valid?
      assert_includes event.errors[:metadata], 'changes must be a JSON object'
    end
  end

  test 'feature flag events require a name and boolean transitions including false' do
    event = AuditEventService.log(action: 'feature_flag_toggled', actor: @actor,
                                  metadata: { flag_name: 'test_feature', old_value: true, new_value: false, extra: 'context' })
    assert_equal false, event.reload.metadata['new_value']

    %w[flag_name old_value new_value].each do |key|
      invalid = event.metadata.except(key)
      assert_not Event.new(user: @actor, action: event.action, metadata: invalid).valid?, "Accepted missing #{key}"
    end

    [{ flag_name: ' ' }, { flag_name: 1 }, { old_value: 'true' }, { new_value: 0 }].each do |attributes|
      event.metadata = event.metadata.merge(attributes.stringify_keys)
      assert_not event.valid?, "Accepted #{attributes.inspect}"
      event.reload
    end
  end
end
