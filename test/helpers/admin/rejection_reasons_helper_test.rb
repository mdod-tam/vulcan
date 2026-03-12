# frozen_string_literal: true

require 'test_helper'

module Admin
  class RejectionReasonsHelperTest < ActionView::TestCase
    include RejectionReasonsHelper

    test 'rejection_reason_body returns db body when present' do
      reason = create(:rejection_reason, code: 'modal_db_lookup', proof_type: 'income', locale: 'en', body: 'From DB')

      result = rejection_reason_body(
        proof_type: reason.proof_type,
        code: reason.code,
        locale: reason.locale
      )

      assert_equal 'From DB', result
    end

    test 'rejection_reason_body interpolates placeholders when provided' do
      create(:rejection_reason,
             code: 'modal_interpolation',
             proof_type: 'income',
             locale: 'en',
             body: 'Address must match %{address}.')

      result = rejection_reason_body(
        proof_type: 'income',
        code: 'modal_interpolation',
        locale: 'en',
        interpolations: { address: '123 Main St' }
      )

      assert_equal 'Address must match 123 Main St.', result
    end

    test 'rejection_reason_body falls back to humanized code when missing' do
      result = rejection_reason_body(
        proof_type: 'income',
        code: 'no_matching_db_record',
        locale: 'en'
      )

      assert_equal 'No matching db record', result
    end
  end
end
