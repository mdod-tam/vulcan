# frozen_string_literal: true

require 'test_helper'

# The master email control, exercised through the public account-access request and real mail jobs.
class EmailMasterSwitchTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    ensure_system_audit_actor!
    @user = create(:constituent)
    load_seeded_email_templates('user_mailer_password_reset')
    ActionMailer::Base.deliveries.clear
  end

  test 'an account access email queued before an off and on interval is not sent' do
    request_account_access

    set_email(false, 'op-1')
    set_email(true, 'op-2')
    perform_enqueued_jobs

    assert_empty ActionMailer::Base.deliveries
    assert_suppressed('pending_canceled', 'UserMailer#password_reset')
  end

  test 'with email off the public response is unchanged and nothing is sent until email is back on' do
    set_email(false, 'op-1')

    request_account_access
    assert_redirected_to sign_in_path
    notice = flash[:notice]
    perform_enqueued_jobs

    assert_empty ActionMailer::Base.deliveries
    assert_suppressed('global_disabled', 'UserMailer#password_reset')

    set_email(true, 'op-2')
    request_account_access
    assert_equal notice, flash[:notice]
    perform_enqueued_jobs

    assert_equal [[@user.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a queued email carries the context captured when it was requested' do
    request_account_access

    job = enqueued_jobs.find { |queued| queued['job_class'] == 'EmailDelivery::MailDeliveryJob' }
    context = job['email_delivery_context']
    controls = [EmailDelivery::ALL_CONTROL, EmailDelivery.category_control('account_security')].map do |name|
      FeatureFlag.find_by!(name: name)
    end
    assert_equal(controls.map { |control| { 'control' => control.name, 'id' => control.id, 'generation' => control.delivery_generation } },
                 context['scopes'])
    assert_equal EmailDelivery::GLOBAL_CONTROL, context.dig('channels', 'email', 'control')
    templates = EmailTemplate.where(name: 'user_mailer_password_reset', format: :text).order(:id)
    assert_equal(templates.map { |row| { 'name' => row.name, 'locale' => row.locale, 'id' => row.id, 'generation' => row.delivery_generation } },
                 context['templates'])
    assert_equal 'UserMailer#password_reset', context['mail_action']
  end

  test 'an immediate delivery is stopped while email is off' do
    set_email(false, 'op-1')

    UserMailer.with(user: @user).password_reset.deliver_now

    assert_empty ActionMailer::Base.deliveries
    assert_suppressed('global_disabled', 'UserMailer#password_reset')
  end

  test 'a letter-preference route still prints while email is off' do
    load_seeded_email_templates('evaluator_mailer_evaluation_submission_confirmation')
    evaluation = create(:evaluation)
    evaluation.constituent.update!(communication_preference: 'letter')
    set_email(false, 'op-1')
    Letters::TextTemplateToPdfService.any_instance.expects(:queue_for_printing).once

    perform_enqueued_jobs do
      EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_later
    end

    assert_empty ActionMailer::Base.deliveries
    assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
  end

  private

  def request_account_access
    post password_path, params: { contact: @user.email }
  end

  def set_email(enabled, operation_id)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: enabled, actor: @admin,
                                     operation_id: operation_id)
  end

  def assert_suppressed(reason, mail_action)
    event = Event.where(action: EmailDelivery::Outcome::SUPPRESSED).order(:id).last
    assert event, 'no suppression was recorded'
    assert_equal reason, event.metadata['reason']
    assert_equal mail_action, event.metadata['mail_action']
  end
end
