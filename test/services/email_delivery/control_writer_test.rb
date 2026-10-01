# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class ControlWriterTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @control = FeatureFlag.find_by!(name: GLOBAL_CONTROL)
    end

    test 'turning email off bumps the generation once and records the change' do
      result = set(false, 'op-1')

      assert result.changed?
      @control.reload
      assert_not @control.enabled
      assert_equal 1, @control.delivery_generation
      event = Event.find_by!(action: ControlWriter::AUDIT_ACTION, auditable: @control)
      assert_equal 'op-1', event.metadata['operation_id']
      assert event.metadata['canceled_pending']
    end

    test 'turning email on keeps the generation and an already-off control is unchanged' do
      set(false, 'op-1')
      assert_equal :unchanged, set(false, 'op-2').status
      set(true, 'op-3')

      assert_equal 1, @control.reload.delivery_generation
      assert @control.enabled
    end

    test 'off, on, off within seconds records three changes and two cancellations' do
      set(false, 'op-1')
      set(true, 'op-2')
      set(false, 'op-3')

      assert_equal 2, @control.reload.delivery_generation
      assert_equal 3, Event.where(action: ControlWriter::AUDIT_ACTION, auditable: @control).count
    end

    test 'a retried operation is applied once, even after the dedup window' do
      set(false, 'op-1')
      set(true, 'op-2')

      travel 1.minute do
        assert_equal :already_applied, set(false, 'op-1').status
      end

      @control.reload
      assert @control.enabled
      assert_equal 1, @control.delivery_generation
    end

    test 'a stale form does not reverse a newer change' do
      set(false, 'op-1')

      result = ControlWriter.set(name: GLOBAL_CONTROL, enabled: false, actor: @admin, operation_id: 'op-2',
                                 expected_enabled: true)

      assert result.stale?
      assert_equal 1, @control.reload.delivery_generation
    end

    test 'an unknown control name is rejected' do
      assert_raises(ArgumentError) do
        ControlWriter.set(name: 'vouchers_enabled', enabled: false, actor: @admin, operation_id: 'op-1')
      end
    end

    private

    def set(enabled, operation_id)
      ControlWriter.set(name: GLOBAL_CONTROL, enabled: enabled, actor: @admin, operation_id: operation_id)
    end
  end
end
