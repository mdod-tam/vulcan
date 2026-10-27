# frozen_string_literal: true

require 'test_helper'

module Baseline
  class FeatureFlagsTest < ActiveSupport::TestCase
    setup do
      @actor = create(:admin)
    end

    test 'reset restores general flag defaults' do
      FeatureFlag.enable!(:vouchers_enabled)

      FeatureFlags.reset!(actor: @actor)

      assert_not FeatureFlag.enabled?(:vouchers_enabled)
      assert_not FeatureFlag.enabled?(:dcf_auto_request_certification)
    end

    test 'reset turns controls back on through the writer, keeping row identity and cancellation generation' do
      control = FeatureFlag.find_by!(name: 'email.category.vendor')
      EmailDelivery::ControlWriter.set(name: control.name, enabled: false, actor: @actor, operation_id: SecureRandom.uuid)
      generation = control.reload.delivery_generation
      assert_operator generation, :>, 0

      assert_difference -> { Event.where(action: EmailDelivery::ControlWriter::AUDIT_ACTION).count }, 1 do
        FeatureFlags.reset!(actor: @actor)
      end

      assert control.reload.enabled
      assert_equal generation, control.delivery_generation
    end

    test 'reset creates a missing control and repeats without changing anything' do
      FeatureFlag.find_by!(name: 'communications.sms').destroy!

      FeatureFlags.reset!(actor: @actor)

      assert FeatureFlag.find_by!(name: 'communications.sms').enabled
      assert_no_difference ['FeatureFlag.count', 'Event.count'] do
        FeatureFlags.reset!(actor: @actor)
      end
      assert_equal FeatureFlags::DEFAULTS, FeatureFlag.where(name: FeatureFlags::DEFAULTS.keys).pluck(:name, :enabled).to_h
    end
  end
end
