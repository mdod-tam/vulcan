# frozen_string_literal: true

require 'test_helper'

class DiagnosticPrivacyTest < ActiveSupport::TestCase
  PRIVATE_DETAIL = 'Private Patient private-diagnostic@example.test 410-555-0199 token=private-diagnostic-token'

  test 'both timeline readers preserve their fallback without logging database details' do
    error = private_error
    application_builder = Applications::AuditLogBuilder.new(Application.new)
    application_builder.stubs(:build_creation_event).raises(error)
    voucher_builder = Vouchers::VoucherAuditLogBuilder.new(Voucher.new)
    Event.stubs(:where).raises(error)

    [application_builder, voucher_builder].each do |builder|
      log = capture_log { assert_empty builder.build_audit_logs }

      assert_includes log, error.class.name
      assert_private_detail_absent(log)
      assert_not_empty builder.errors
    end
  end

  test 'equipment report failure sends only the error class to the reporter and keeps the unavailable response' do
    error = private_error
    report = Reports::EquipmentByTypeReport.new(period: :current_month, include_voucher_counts: false)
    report.stubs(:non_voucher_equipment_counts).raises(error)
    reported_error = nil
    Rails.error.expects(:report).with do |reported, **options|
      reported_error = reported
      options[:handled] && options[:context][:period] == 'current_month'
    end

    log = capture_log do
      result = report.call
      assert_not result.success?
      assert_equal Reports::EquipmentByTypeReport::UNAVAILABLE_MESSAGE, result.message
      assert_empty result.data[:rows]
    end

    assert_not_same error, reported_error
    assert_equal error.class.name, reported_error.message
    assert_nil reported_error.cause
    assert_private_detail_absent(log)
  end

  test 'a handled report reaches the log with its class-only message, backtrace, and context, and an unhandled one does not' do
    reported = StandardError.new('ActiveRecord::StatementInvalid')
    reported.set_backtrace(["app/services/example.rb:1:in 'call'"])

    log = capture_log do
      Rails.error.report(reported, handled: true, context: { application_id: 7 })
      Rails.error.report(RuntimeError.new('unhandled framework failure'), handled: false)
    end

    assert_includes log, 'ActiveRecord::StatementInvalid context={"application_id":7}'
    assert_includes log, "app/services/example.rb:1:in 'call'"
    assert_not_includes log, 'unhandled framework failure'
  end

  test 'a report made during a request logs only the caller context, never the controller or request' do
    controller = Object.new
    controller.instance_variable_set(:@session, PRIVATE_DETAIL)
    controller.instance_variable_set(:@self, controller)

    log = capture_log do
      ActiveSupport::ExecutionContext.set(controller: controller, request: controller) do
        Rails.error.report(StandardError.new('ArgumentError'), handled: true, context: { application_id: 7 })
      end
    end

    assert_includes log, 'ArgumentError context={"application_id":7}'
    assert_private_detail_absent(log)
  end

  test 'shared user failure logging does not copy validation details into diagnostics' do
    adapter = Object.new.extend(UserServiceIntegration)
    record = User.new
    record.errors.add(:base, PRIVATE_DETAIL)

    log = capture_log { adapter.log_user_service_error('creating dependent', record.errors) }

    assert_includes log, 'creating dependent'
    assert_private_detail_absent(log)
  end

  test 'malformed notification metadata is discarded without inspecting its contents' do
    application = create(:application)
    admin = create(:admin)
    log = capture_log do
      notification = NotificationService.create_and_deliver!(
        type: :proof_approved, recipient: application.user, actor: admin, notifiable: application, metadata: PRIVATE_DETAIL
      )
      assert_not_nil notification
      assert_not_includes notification.metadata.to_json, PRIVATE_DETAIL
    end

    assert_includes log, 'Metadata received as String'
    assert_private_detail_absent(log)
  end

  private

  def private_error
    ActiveRecord::StatementInvalid.new(PRIVATE_DETAIL).tap do |error|
      error.set_backtrace(["#{PRIVATE_DETAIL}:1:in failure"])
    end
  end

  def capture_log(&)
    output = StringIO.new
    Rails.stub(:logger, ActiveSupport::Logger.new(output), &)
    output.string
  end

  def assert_private_detail_absent(log)
    ['Private Patient', 'private-diagnostic@example.test', '410-555-0199', 'private-diagnostic-token'].each do |value|
      assert_not_includes log, value
    end
  end
end
