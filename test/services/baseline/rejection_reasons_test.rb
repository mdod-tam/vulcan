# frozen_string_literal: true

require 'test_helper'

module Baseline
  class RejectionReasonsTest < ActiveSupport::TestCase
    setup do
      @actor = create(:admin)
      @definition = RejectionReasons::DEFINITIONS.first
      @pair = @definition.slice(:code, :proof_type)
    end

    test 'reset restores an edited body with its version history and leaves the pair synchronized' do
      english = RejectionReason.find_by!(**@pair, locale: 'en')
      english.update!(body: 'Staff-edited body', updated_by: @actor)
      version = english.reload.version
      assert RejectionReason.find_by!(**@pair, locale: 'es').needs_sync

      RejectionReasons.reset!(actor: @actor)

      english.reload
      assert_equal @definition[:en_body], english.body
      assert_equal version + 1, english.version
      assert_equal 'Staff-edited body', english.previous_body
      assert_equal [false, false], RejectionReason.where(**@pair).order(:locale).pluck(:needs_sync)
    end

    test 'reset converges when both locales were edited or a stale flag blocks a save' do
      RejectionReason.find_by!(**@pair, locale: 'en').update!(body: 'Edited English', updated_by: @actor)
      RejectionReason.find_by!(**@pair, locale: 'es').update!(body: 'Español editado', updated_by: @actor)
      RejectionReason.find_by!(**@pair, locale: 'en').update_columns(needs_sync: true)

      RejectionReasons.reset!(actor: @actor)

      assert_equal [@definition[:en_body], @definition[:es_body]], RejectionReason.where(**@pair).order(:locale).pluck(:body)
      assert_equal [false, false], RejectionReason.where(**@pair).order(:locale).pluck(:needs_sync)
    end

    test 'reset creates a missing reason, is repeatable, and leaves an unrelated reason alone' do
      custom = RejectionReason.create!(code: 'staff_custom', proof_type: 'income', locale: 'en', body: 'Custom')
      RejectionReason.find_by!(**@pair, locale: 'es').destroy!

      assert_difference 'RejectionReason.count', 1 do
        RejectionReasons.reset!(actor: @actor)
      end
      assert_no_difference ['RejectionReason.count', -> { RejectionReason.sum(:version) }] do
        RejectionReasons.reset!(actor: @actor)
      end
      assert_equal 'Custom', custom.reload.body
    end
  end
end
