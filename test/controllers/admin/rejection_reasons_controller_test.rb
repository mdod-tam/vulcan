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

    test 'index links to the new reason form' do
      get admin_rejection_reasons_path

      assert_select 'a[href=?]', new_admin_rejection_reason_path, text: 'New Rejection Reason'
    end

    test 'new asks for a proof type, a name, and the text in both languages' do
      get new_admin_rejection_reason_path

      assert_response :success
      assert_select 'select#rejection_reason_proof_type option', count: RejectionReason::VALID_PROOF_TYPES.size + 1
      assert_select 'select#rejection_reason_proof_type option', text: 'ID'
      assert_select 'label[for=rejection_reason_name]', text: 'Reason name'
      assert_select 'textarea#rejection_reason_en_body'
      assert_select 'textarea#rejection_reason_es_body[lang=es]'
    end

    test 'create stores the reason in both languages under a code made from its name' do
      assert_difference 'RejectionReason.count', 2 do
        post admin_rejection_reasons_path, params: { rejection_reason: {
          proof_type: 'id', name: 'Photo is blurry', en_body: 'Please send a clearer photo.', es_body: 'Envíe una foto más clara.'
        } }
      end

      english = RejectionReason.find_by!(code: 'photo_is_blurry', proof_type: 'id', locale: 'en')
      spanish = RejectionReason.find_by!(code: 'photo_is_blurry', proof_type: 'id', locale: 'es')
      assert_redirected_to edit_admin_rejection_reason_path(english)
      assert_equal 'Envíe una foto más clara.', spanish.body
      assert_equal [@admin.id] * 2, [english.updated_by_id, spanish.updated_by_id]
      assert_equal [false, false], [english.needs_sync?, spanish.needs_sync?]
      assert_equal 'Photo Is Blurry', RejectionReason.label_for(english.code)
      assert_includes RejectionReason.options_for(locale: 'es', proof_type: 'id').map(&:body), 'Envíe una foto más clara.'
    end

    test 'create refuses a name already used for that proof type but allows it for another' do
      create(:rejection_reason, code: 'photo_is_blurry', proof_type: 'id')
      params = { name: 'Photo is blurry', en_body: 'Clearer, please.', es_body: 'Más clara, por favor.' }

      assert_no_difference 'RejectionReason.count' do
        post admin_rejection_reasons_path, params: { rejection_reason: params.merge(proof_type: 'id') }
      end
      assert_response :unprocessable_content
      assert_select 'li', text: /Reason name is already used/

      assert_difference 'RejectionReason.count', 2 do
        post admin_rejection_reasons_path, params: { rejection_reason: params.merge(proof_type: 'residency') }
      end
    end

    test 'create refuses a missing language, an unknown proof type, and the choices forms already offer' do
      valid = { proof_type: 'income', name: 'Pay stub cut off', en_body: 'Send the whole page.', es_body: 'Envíe la página completa.' }

      [
        [valid.merge(es_body: ''), /Reason text \(Spanish\) can't be blank/],
        [valid.merge(proof_type: 'medical_certification'), /Proof type is not included/],
        [valid.merge(name: 'Other'), /Reason name is reserved/],
        [valid.merge(name: '!!!'), /Reason name must include letters or numbers/]
      ].each do |params, message|
        assert_no_difference 'RejectionReason.count' do
          post admin_rejection_reasons_path, params: { rejection_reason: params }
        end
        assert_response :unprocessable_content
        assert_select 'li', text: message
      end
    end

    test 'create refuses a placeholder the forms cannot fill and keeps what was typed' do
      assert_no_difference 'RejectionReason.count' do
        post admin_rejection_reasons_path, params: { rejection_reason: {
          proof_type: 'income', name: 'Pay stub cut off', en_body: 'Dear %<first_name>s, send the whole page.', es_body: 'Envíe la página completa.'
        } }
      end

      assert_response :unprocessable_content
      assert_select 'li', text: /Reason text \(English\) uses placeholders that are not supported: first_name/
      assert_select 'textarea#rejection_reason_en_body', text: /Dear %<first_name>s/
      assert_select 'input#rejection_reason_name[value=?]', 'Pay stub cut off'
    end

    test 'create is limited to administrators' do
      sign_in_as create(:constituent)

      assert_no_difference 'RejectionReason.count' do
        post admin_rejection_reasons_path, params: { rejection_reason: {
          proof_type: 'income', name: 'Pay stub cut off', en_body: 'Send the whole page.', es_body: 'Envíe la página completa.'
        } }
      end
      assert_not_equal 200, response.status
    end
  end
end
