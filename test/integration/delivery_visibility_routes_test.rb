# frozen_string_literal: true

require 'test_helper'

class DeliveryVisibilityRoutesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_for_controller_test(create(:admin))
  end

  test 'authorized decision screens render the attempts belonging to their own record' do
    voucher = create(:voucher)
    invoice = create(:invoice)
    evaluation = create(:evaluation)
    training = create(:training_session)
    routes = { voucher => admin_voucher_path(voucher), invoice => admin_invoice_path(invoice),
               evaluation => evaluators_evaluation_path(evaluation), training => trainers_training_session_path(training) }
    routes.each do |record, path|
      EmailDeliveryAttempt.create!(origin: record, correlation_id: SecureRandom.uuid, destination: 'masked-person@example.test',
                                   recipient_key: EmailDeliveryAttempt.recipient_key('masked-person@example.test'), server_id: 'default',
                                   mail_action: 'UserMailer#password_reset', attempted_at: Time.current, delivered_at: Time.current)
      get path
      assert_response :success
      assert_select '[data-delivery-status="delivered"]', count: 1
      assert_select 'summary', text: 'Details', minimum: 1
      assert_includes response.body, 'm***@example.test'
      assert_not_includes response.body, 'masked-person'
    end
  end
end
