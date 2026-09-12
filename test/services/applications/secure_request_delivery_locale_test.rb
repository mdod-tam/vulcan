# frozen_string_literal: true

require 'test_helper'

module Applications
  class SecureRequestDeliveryLocaleTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @actor = create(:admin)
      @generic_guardian = create(:constituent, locale: 'en')
      @owner = create(:constituent, locale: 'es', phone_type: 'text')
      @dependent = create(:constituent, locale: 'en', dependent_email: @owner.email)
      create(:guardian_relationship, guardian_user: @generic_guardian, dependent_user: @dependent, relationship_type: 'Parent')
      create(:guardian_relationship, guardian_user: @owner, dependent_user: @dependent, relationship_type: 'Parent')
      @application = create(:application, :in_progress, user: @dependent, managing_guardian: @owner)
      assert_equal :en, @dependent.effective_message_locale
    end

    [RequestProviderInfo, RequestProofResubmission].each do |service|
      test "#{service.name} resend uses the new delivery owner and language" do
        SmsService.stubs(:send_message).returns(true)
        args = { application: @application, actor: @actor, recipient_ids: [@dependent.id],
                 channel_overrides: { @dependent.id => 'sms' } }
        args[:proof_type] = :id if service == RequestProofResubmission
        first = service.new(**args).call
        assert_predicate first, :success?
        original = first.data.fetch(:secure_request_forms).first
        assert_equal :es, original.delivery_locale
        new_owner = create(:constituent, locale: 'en', phone_type: 'text')
        create(:guardian_relationship, guardian_user: new_owner, dependent_user: @dependent, relationship_type: 'Parent')
        @dependent.update!(dependent_email: new_owner.email)
        @application.update!(managing_guardian: new_owner)
        SmsService.expects(:send_message).with do |phone, body, **options|
          phone == new_owner.phone && body.start_with?('MAT needs') && options[:sensitive]
        end.returns(true)
        travel 2.hours

        result = service.new(**args, resend_of: original).call

        assert_predicate result, :success?
        replacement = result.data.fetch(:secure_request_forms).first
        assert_equal new_owner.id, replacement.delivery_owner_id
        assert_equal :en, replacement.delivery_locale
        assert_equal @owner.id, original.reload.delivery_owner_id
        assert_predicate original, :revoked?
      end

      test "#{service.name} SMS follows channel owner and safely falls back for unsupported locale" do
        ['es', 'unsupported', nil].each do |locale|
          @owner.update!(locale: locale)
          expected_locale = locale == 'es' ? :es : I18n.default_locale
          prefix = service == RequestProviderInfo ? 'secure_provider_info_forms' : 'secure_proof_forms'
          SmsService.expects(:send_message).with do |phone, body, **options|
            translated_prefix = I18n.t("#{prefix}.sms.message", locale: expected_locale,
                                                                secure_url: '', hours: 48,
                                                                proof_type: I18n.t('secure_proof_forms.proof_types.id', locale: expected_locale)).split('  ').first
            phone == @owner.phone && body.start_with?(translated_prefix) && options[:sensitive]
          end.returns(true)
          args = { application: @application, actor: @actor, recipient_ids: [@dependent.id],
                   channel_overrides: { @dependent.id => 'sms' } }
          args[:proof_type] = :id if service == RequestProofResubmission
          result = service.new(**args).call
          assert_predicate result, :success?
          form = result.data.fetch(:secure_request_forms).first
          assert_equal @owner.id, form.delivery_owner_id
          assert_equal expected_locale, form.delivery_locale
          assert_predicate form.reload, :active?
          travel 2.hours
        end
      end
    end
  end
end
