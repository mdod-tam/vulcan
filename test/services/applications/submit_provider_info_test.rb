# frozen_string_literal: true

require 'test_helper'

module Applications
  class SubmitProviderInfoTest < ActiveSupport::TestCase
    setup do
      @application = create(
        :application,
        status: :awaiting_proof
      )
      @application.update!(
        medical_provider_name: nil,
        medical_provider_phone: nil,
        medical_provider_email: nil,
        medical_provider_fax: nil
      )
      @secure_request_form = create(:secure_request_form, application: @application, recipient: @application.user)
      @params = {
        medical_provider_name: 'Dr. Secure',
        medical_provider_email: 'provider@example.test',
        medical_provider_phone: '410-555-0100',
        medical_provider_fax: '410-555-0101'
      }
    end

    test 'submits provider information and closes the secure request' do
      result = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params
      ).call

      assert_predicate result, :success?
      assert_equal 'Dr. Secure', @application.reload.medical_provider_name
      assert_predicate @secure_request_form.reload, :submitted?
    end

    test 'normalizes provider phone and fax before saving' do
      result = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params.merge(
          medical_provider_phone: '4105550100',
          medical_provider_fax: '4105550101'
        )
      ).call

      assert_predicate result, :success?
      @application.reload
      assert_equal '410-555-0100', @application.medical_provider_phone
      assert_equal '410-555-0101', @application.medical_provider_fax
    end

    test 'revoked submitted and expired requests cannot submit' do
      %i[revoked submitted expired].each do |trait|
        application = create(:application, status: :awaiting_proof)
        request = create(:secure_request_form, trait, application: application, recipient: application.user)

        result = SubmitProviderInfo.new(
          application: application,
          secure_request_form: request,
          params: @params
        ).call

        assert_not result.success?, "#{trait} request should not submit"
      end
    end

    test 'rechecks request status after acquiring the row lock' do
      @secure_request_form.define_singleton_method(:with_lock) do |&block|
        update!(status: :submitted, submitted_at: Time.current)
        block.call
      end

      assert_no_difference -> { Event.where(action: 'medical_provider_info_submitted').count } do
        result = SubmitProviderInfo.new(
          application: @application,
          secure_request_form: @secure_request_form,
          params: @params
        ).call

        assert_not result.success?
        assert_equal I18n.t('applications.provider_info.messages.already_submitted',
                            locale: @secure_request_form.recipient.effective_locale),
                     result.message
      end

      assert_nil @application.reload.medical_provider_name
    end

    test 'rejects a secure request form for a different application' do
      other_application = create(:application, status: :awaiting_proof)
      other_application.update!(
        medical_provider_name: nil,
        medical_provider_phone: nil,
        medical_provider_email: nil,
        medical_provider_fax: nil
      )

      result = SubmitProviderInfo.new(
        application: other_application,
        secure_request_form: @secure_request_form,
        params: @params
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.invalid_request',
                          locale: @secure_request_form.recipient.effective_locale),
                   result.message
      assert_nil other_application.reload.medical_provider_name
      assert_predicate @secure_request_form.reload, :status_sent?
    end

    test 'rejects proof-resubmission request forms without updating provider info' do
      %i[id_proof_resubmission residency_proof_resubmission income_proof_resubmission].each do |proof_kind|
        request = create(:secure_request_form, application: @application, recipient: @application.user, kind: proof_kind)

        assert_no_difference -> { Event.where(action: 'medical_provider_info_submitted').count } do
          result = SubmitProviderInfo.new(
            application: @application,
            secure_request_form: request,
            params: @params
          ).call

          assert_not result.success?, "#{proof_kind} request should not submit provider info"
          assert_equal I18n.t('applications.provider_info.messages.invalid_request',
                              locale: request.recipient.effective_locale),
                       result.message
        end

        assert_nil @application.reload.medical_provider_name
        assert_predicate request.reload, :status_sent?
      end
    end

    test 'requires provider name phone and valid email' do
      service = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: {
          medical_provider_name: '',
          medical_provider_phone: '',
          medical_provider_email: 'not-an-email'
        }
      )
      result = service.call

      assert_not result.success?
      assert_equal result.data.fetch(:errors), service.form_errors
      assert_includes result.data.fetch(:errors).attribute_names, :medical_provider_name
      assert_includes result.data.fetch(:errors).attribute_names, :medical_provider_phone
      assert_includes result.data.fetch(:errors).attribute_names, :medical_provider_email
    end

    test 'blank provider phone only adds the required-field error' do
      service = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params.merge(medical_provider_phone: '')
      )
      result = service.call

      assert_not result.success?
      phone_errors = result.data.fetch(:errors).where(:medical_provider_phone)
      assert_equal 1, phone_errors.size
      assert_equal I18n.t('applications.provider_info.messages.medical_provider_phone_blank',
                          locale: @secure_request_form.recipient.effective_locale),
                   phone_errors.first.message
    end

    test 'rejects provider phone and fax values outside the allowed 10-digit formats' do
      service = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params.merge(
          medical_provider_phone: 'office phone ext 12',
          medical_provider_fax: '(410) 555-0101'
        )
      )
      result = service.call

      assert_not result.success?
      assert_includes result.data.fetch(:errors).attribute_names, :medical_provider_phone
      assert_includes result.data.fetch(:errors).attribute_names, :medical_provider_fax
    end

    test 'allows blank provider fax' do
      result = SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params.merge(medical_provider_fax: '')
      ).call

      assert_predicate result, :success?
      assert_equal '', @application.reload.medical_provider_fax
    end

    # -----------------------------------------------------------------------
    # Transaction rollback: application.update! raises
    # -----------------------------------------------------------------------

    test 'does not mark secure request submitted or create audit event when application update rolls back' do
      @application.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@application))

      assert_no_difference -> { Event.where(action: 'medical_provider_info_submitted').count } do
        SubmitProviderInfo.new(
          application: @application,
          secure_request_form: @secure_request_form,
          params: @params
        ).call
      end

      @secure_request_form.reload
      assert_not_predicate @secure_request_form, :submitted?
      assert_predicate @secure_request_form, :status_sent?
    end

    # -----------------------------------------------------------------------
    # Audit metadata shape and PII exclusion
    # -----------------------------------------------------------------------

    test 'successful submission creates exactly one medical_provider_info_submitted event' do
      assert_difference -> { Event.where(action: 'medical_provider_info_submitted').count }, 1 do
        SubmitProviderInfo.new(
          application: @application,
          secure_request_form: @secure_request_form,
          params: @params
        ).call
      end
    end

    test 'submission audit metadata contains all required keys' do
      SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params
      ).call

      event = Event.find_by!(action: 'medical_provider_info_submitted', auditable: @application)
      metadata = event.metadata.deep_stringify_keys

      assert_equal @secure_request_form.id.to_s, metadata['secure_request_form_id'].to_s
      assert_equal @secure_request_form.recipient_id.to_s, metadata['recipient_user_id'].to_s
      assert_includes %w[constituent guardian], metadata['recipient_role']
      assert_includes metadata.keys, 'request_batch_id'
      assert_includes metadata.keys, 'changed_fields'
      assert_includes metadata.keys, 'previous_presence'
      assert_includes metadata.keys, 'submitted_presence'
    end

    test 'submission audit metadata records submitted_via as secure_request_form without going through SubmissionMethodValidator' do
      SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params
      ).call

      event = Event.find_by!(action: 'medical_provider_info_submitted', auditable: @application)

      assert_equal 'secure_request_form', event.metadata.deep_stringify_keys['submitted_via']
    end

    test 'submission audit metadata does not contain raw provider PII' do
      raw_provider_name = 'Dr. PII Should Not Leak'
      raw_provider_email = 'pii-should-not-leak@example.test'
      raw_provider_phone = '4105550199'
      raw_provider_fax = '4105550198'

      SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: {
          medical_provider_name: raw_provider_name,
          medical_provider_email: raw_provider_email,
          medical_provider_phone: raw_provider_phone,
          medical_provider_fax: raw_provider_fax
        }
      ).call

      event = Event.find_by!(action: 'medical_provider_info_submitted', auditable: @application)
      metadata_json = event.metadata.to_json

      assert_not_includes metadata_json, raw_provider_name
      assert_not_includes metadata_json, raw_provider_email
      assert_not_includes metadata_json, raw_provider_phone
      assert_not_includes metadata_json, raw_provider_fax
    end

    test 'submission audit metadata includes presence flags not raw field values' do
      SubmitProviderInfo.new(
        application: @application,
        secure_request_form: @secure_request_form,
        params: @params
      ).call

      event = Event.find_by!(action: 'medical_provider_info_submitted', auditable: @application)
      submitted_presence = event.metadata.deep_stringify_keys['submitted_presence']

      assert_kind_of Hash, submitted_presence
      # Presence values must be booleans, not the raw field values
      submitted_presence.each_value do |v|
        assert_includes [true, false], v, "Expected boolean presence flag, got #{v.inspect}"
      end
    end
  end
end
