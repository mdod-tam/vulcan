# frozen_string_literal: true

require 'test_helper'

class DeliveryErrorAuditTest < ActiveSupport::TestCase
  [EvaluatorMailer, TrainingSessionNotificationsMailer, VoucherNotificationsMailer].each do |mailer_class|
    test "#{mailer_class} records sanitized diagnostics without template variables" do
      delivery = case mailer_class.name
                 when 'EvaluatorMailer'
                   EvaluatorMailer.with(evaluation: create(:evaluation)).new_evaluation_assigned
                 when 'TrainingSessionNotificationsMailer'
                   TrainingSessionNotificationsMailer.training_scheduled(create(:training_session, :scheduled))
                 when 'VoucherNotificationsMailer'
                   VoucherNotificationsMailer.with(voucher: create(:voucher)).voucher_assigned
                 end
      raw = 'token=secret-value someone@example.test +12025550199 https://example.test/private'
      error = StandardError.new(raw)
      error.set_backtrace([raw])
      mailer_class.any_instance.stubs(:send_email).raises(error)

      assert_same error, assert_raises(StandardError) { delivery.message }

      metadata = Event.where(action: 'email_delivery_error').order(:id).last.metadata
      assert_not metadata.key?('variables')
      assert_equal %w[__service_generated backtrace error_class error_message ip_address mail_action template_name user_agent], metadata.keys.sort
      %w[secret-value someone@example.test +12025550199 https://example.test/private].each do |sensitive|
        assert_not_includes metadata.to_json, sensitive
      end
      assert_equal 'StandardError', metadata['error_class']
    end
  end

  test 'an audit failure does not mask the mailer exception' do
    user = create(:constituent)
    error = StandardError.new('original failure')
    UserMailer.any_instance.stubs(:send_email).raises(error)
    AuditEventService.stubs(:log).raises(StandardError, 'audit unavailable')

    assert_same error, assert_raises(StandardError) { UserMailer.with(user: user).password_reset.message }
  end

  test 'a failure before variables exist keeps the original exception' do
    user = create(:constituent)
    error = StandardError.new('lookup unavailable')
    UserMailer.any_instance.stubs(:find_text_template).raises(error)

    assert_same error, assert_raises(StandardError) { UserMailer.with(user: user).password_reset.message }
    assert_not Event.where(action: 'email_delivery_error', user: user).last.metadata.key?('variables')
  end
end
