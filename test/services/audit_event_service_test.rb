# frozen_string_literal: true

require 'test_helper'

class AuditEventServiceTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @template = create(:email_template, :text)
  end

  test 'distinct operation ids log distinct events inside the dedup window' do
    log_toggle(enabled: false, operation_id: 'op-1')
    log_toggle(enabled: true, operation_id: 'op-2')
    log_toggle(enabled: false, operation_id: 'op-3')

    assert_equal 3, toggle_events.count
  end

  test 'a retried operation id is suppressed inside the dedup window' do
    log_toggle(enabled: false, operation_id: 'op-1')

    assert_nil log_toggle(enabled: false, operation_id: 'op-1')
    assert_equal 1, toggle_events.count
  end

  test 'events without an operation id keep the action fingerprint' do
    log_toggle(enabled: false)

    assert_nil log_toggle(enabled: true)
    assert_equal 1, toggle_events.count
  end

  private

  def log_toggle(enabled:, operation_id: nil)
    AuditEventService.log(
      action: 'email_template_toggled',
      actor: @admin,
      auditable: @template,
      metadata: { enabled: enabled, operation_id: operation_id }.compact
    )
  end

  def toggle_events
    Event.where(action: 'email_template_toggled', auditable: @template)
  end
end
