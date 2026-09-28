# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class PolicyTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @context = Policy.capture(mail_action: 'UserMailer#password_reset')
    end

    test 'an email captured while email is on may be sent' do
      assert Policy.verify(@context).allowed?
    end

    test 'turning email off suppresses captured mail' do
      set(false, 'op-1')

      assert_equal 'global_disabled', Policy.verify(@context).reason
    end

    test 'mail captured before an off and on interval stays canceled' do
      set(false, 'op-1')
      set(true, 'op-2')

      assert_equal 'pending_canceled', Policy.verify(@context).reason
      assert Policy.verify(Policy.capture(mail_action: 'UserMailer#password_reset')).allowed?
    end

    test 'a recreated control does not authorize mail captured under the old row' do
      FeatureFlag.find_by!(name: GLOBAL_CONTROL).destroy!
      FeatureFlag.create!(name: GLOBAL_CONTROL, enabled: true)

      assert_equal 'pending_canceled', Policy.verify(@context).reason
    end

    test 'a missing control is a configuration error, not a send' do
      FeatureFlag.find_by!(name: GLOBAL_CONTROL).destroy!

      assert Policy.verify(@context).configuration_error?
      assert Policy.verify(Policy.capture(mail_action: 'UserMailer#password_reset')).configuration_error?
    end

    test 'a queued email without a context is not sent' do
      assert_equal 'legacy_context_missing', Policy.verify(nil).reason
    end

    test 'turning a category off stops only that category, including actions in a mixed mailer' do
      proof = Policy.capture(mail_action: 'ApplicationNotificationsMailer#proof_received')
      registration = Policy.capture(mail_action: 'ApplicationNotificationsMailer#account_created')
      ControlWriter.set(name: EmailDelivery.category_control('proof'), enabled: false, actor: @admin, operation_id: 'op-1')

      assert_equal 'category_disabled', Policy.verify(proof).reason
      assert Policy.verify(registration).allowed?
    end

    test 'turning registration off does not stop password recovery' do
      recovery = Policy.capture(mail_action: 'UserMailer#password_reset')
      ControlWriter.set(name: EmailDelivery.category_control('registration'), enabled: false, actor: @admin,
                        operation_id: 'op-1')

      assert Policy.verify(recovery).allowed?
    end

    test 'turning a template pair off cancels mail for both locales, and turning it on does not revive it' do
      pair = %w[en es].map { |locale| template_row('user_mailer_password_reset', locale) }
      context = Policy.capture(mail_action: 'UserMailer#password_reset')
      assert_equal pair.map(&:id), context['templates'].pluck('id')

      ControlWriter.set_template_pair(name: 'user_mailer_password_reset', format: :text, enabled: false, actor: @admin,
                                      operation_id: 'op-1')
      assert_equal 'template_disabled', Policy.verify(context).reason

      ControlWriter.set_template_pair(name: 'user_mailer_password_reset', format: :text, enabled: true, actor: @admin,
                                      operation_id: 'op-2')
      assert_equal 'pending_canceled', Policy.verify(context).reason
      assert Policy.verify(Policy.capture(mail_action: 'UserMailer#password_reset')).allowed?
    end

    test 'a test send follows the category of the template being tested' do
      template_row('voucher_notifications_voucher_assigned', 'en')
      ControlWriter.set(name: EmailDelivery.category_control('voucher'), enabled: false, actor: @admin, operation_id: 'op-1')

      context = Policy.capture(mail_action: 'AdminTestMailer#test_email',
                               params: { template_name: 'voucher_notifications_voucher_assigned', format: 'text' })

      assert_equal 'category_disabled', Policy.verify(context).reason
    end

    test 'a shared fragment cannot be test-sent' do
      context = Policy.capture(mail_action: 'AdminTestMailer#test_email',
                               params: { template_name: 'email_header_text', format: 'text' })

      assert Policy.verify(context).configuration_error?
    end

    test 'a missing category control is a configuration error' do
      FeatureFlag.find_by!(name: EmailDelivery.category_control('proof')).destroy!

      assert Policy.verify(Policy.capture(mail_action: 'ApplicationNotificationsMailer#proof_received')).configuration_error?
    end

    private

    def template_row(name, locale)
      EmailTemplate.find_by(name: name, format: :text, locale: locale) ||
        create(:email_template, :text, name: name, locale: locale)
    end

    def set(enabled, operation_id)
      ControlWriter.set(name: GLOBAL_CONTROL, enabled: enabled, actor: @admin, operation_id: operation_id)
    end
  end
end
