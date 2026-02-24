# frozen_string_literal: true

require 'test_helper'

module Admin
  class RejectionReasonsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_as @admin
    end

    test 'index groups reasons by proof type and code' do
      code = "missing_name_#{SecureRandom.hex(4)}"
      create(:rejection_reason, code: code, proof_type: 'income', locale: 'en')
      create(:rejection_reason, code: code, proof_type: 'income', locale: 'es')

      get admin_rejection_reasons_path

      assert_response :success
      group = assigns(:reason_groups).find do |entry|
        entry[:proof_type] == 'income' && entry[:code] == code
      end
      assert_not_nil group
      assert_equal 'income', group[:proof_type]
      assert_equal code, group[:code]
      assert_equal 'en', group[:en].locale
      assert_equal 'es', group[:es].locale
    end

    test 'update changes body and sets updated_by' do
      reason = create(:rejection_reason, locale: 'en', body: 'Original reason text')

      patch admin_rejection_reason_path(reason), params: {
        rejection_reason: { body: 'Updated reason text' }
      }

      assert_redirected_to edit_admin_rejection_reason_path(reason)
      reason.reload
      assert_equal 'Updated reason text', reason.body
      assert_equal @admin.id, reason.updated_by_id
      assert_operator reason.version, :>=, 2
    end

    test 'update renders edit on validation failure' do
      reason = create(:rejection_reason, locale: 'en', body: 'Original reason text')

      patch admin_rejection_reason_path(reason), params: {
        rejection_reason: { body: '' }
      }

      assert_response :unprocessable_content
      assert_includes response.body, 'prevented this rejection reason from saving'
    end

    test 'mark_synced clears needs_sync' do
      reason = create(:rejection_reason, locale: 'en', needs_sync: true)

      patch mark_synced_admin_rejection_reason_path(reason)

      assert_redirected_to edit_admin_rejection_reason_path(reason)
      assert_equal 'Rejection reason marked as synced.', flash[:notice]
      reason.reload
      assert_not reason.needs_sync?
    end
  end
end
