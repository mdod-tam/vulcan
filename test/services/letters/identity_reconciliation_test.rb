# frozen_string_literal: true

require 'test_helper'

module Letters
  class IdentityReconciliationTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @context = EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form')
      @items = []
    end

    teardown do
      @items.each { |item| item.pdf_letter.purge }
    end

    test 'profile name edit schedules reconciliation and distinguishes blocked from canceled' do
      item = queue
      sign_in_for_controller_test(@recipient)
      assert_enqueued_with(job: ReconcilePendingJob, args: [{ recipient_id: @recipient.id }]) do
        patch profile_path, params: { user: { first_name: 'Updated' } }
      end
      assert_redirected_to constituent_portal_dashboard_path
      assert_predicate item.reload, :pending?
      assert_equal :blocked, item.display_delivery_state
      assert_nil item.canceled_at

      ReconcilePendingJob.perform_now(recipient_id: @recipient.id)

      assert_predicate item.reload, :canceled?
      assert_equal :canceled, item.display_delivery_state
      assert item.canceled_at
    end

    test 'admin address edit schedules the same recipient reconciliation' do
      item = queue
      sign_in_for_controller_test(@admin)
      assert_enqueued_with(job: ReconcilePendingJob, args: [{ recipient_id: @recipient.id }]) do
        patch admin_user_path(@recipient), params: { user: { physical_address_1: '200 Changed Street' } }
      end
      assert_redirected_to admin_user_path(@recipient)
      ReconcilePendingJob.perform_now(recipient_id: @recipient.id)
      assert_predicate item.reload, :canceled?
    end

    test 'application history renders blocked without claiming durable cancellation' do
      form = create(:secure_request_form, application: @application, recipient: @recipient,
                                          delivery_owner: @recipient, recipient_channel: :letter)
      item = queue(secure_request_form: form)
      @recipient.update!(first_name: 'Changed')
      sign_in_for_controller_test(@admin)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'td span', text: I18n.t('outbound_delivery.letter_blocked')
      assert_select 'td', text: I18n.t('outbound_delivery.letter_canceled'), count: 0
      assert_predicate item.reload, :pending?
      assert_nil item.canceled_at
    end

    test 'rollback unrelated and unchanged writes do not enqueue reconciliation' do
      queue
      assert_no_enqueued_jobs(only: ReconcilePendingJob) do
        User.transaction do
          @recipient.update!(first_name: 'Rolled back')
          raise ActiveRecord::Rollback
        end
        @recipient.reload.update!(phone_type: 'text')
        @recipient.update!(first_name: @recipient.first_name)
      end
    end

    test 'a later unrelated save does not lose the identity change at commit' do
      queue
      assert_enqueued_with(job: ReconcilePendingJob, args: [{ recipient_id: @recipient.id }]) do
        User.transaction do
          @recipient.update!(first_name: 'Changed')
          @recipient.update!(phone_type: 'text')
          assert_no_enqueued_jobs(only: ReconcilePendingJob)
        end
      end
    end

    test 'scoped reconciliation preserves new valid letters unrelated recipients and released history' do
      old = queue
      released = queue
      Delivery.export!([released.id], actor: @admin)
      other_recipient = create(:constituent)
      other = queue(recipient: other_recipient)
      other_recipient.update!(first_name: 'Other changed')
      @recipient.update!(physical_address_1: '200 Changed Street')
      fresh = queue

      2.times { ReconcilePendingJob.perform_now(recipient_id: @recipient.id) }

      assert_predicate old.reload, :canceled?
      assert_predicate fresh.reload, :pending?
      assert_predicate other.reload, :pending?
      assert released.reload.released_at
      assert_predicate released, :pending?
      assert_equal 1, Event.where(action: 'letter_delivery_canceled', auditable: old).count
    end

    test 'application owner edits scope reconciliation to the application' do
      item = queue
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @recipient)
      assert_enqueued_with(job: ReconcilePendingJob, args: [{ application_id: @application.id }]) do
        @application.update!(managing_guardian: guardian)
      end
      ReconcilePendingJob.perform_now(application_id: @application.id)
      assert_predicate item.reload, :canceled?
    end

    test 'a rejected reconciliation enqueue records an audit without losing the contact change' do
      queue
      ReconcilePendingJob.stubs(:perform_later).returns(false)
      assert_difference -> { Event.where(action: 'letter_reconciliation_enqueue_failed').count }, 1 do
        @recipient.update!(first_name: 'Committed')
      end
      assert_equal 'Committed', @recipient.reload.first_name
    end

    test 'batch continuation retains recipient scope and records a rejected enqueue' do
      first = queue
      second = queue
      @recipient.update!(first_name: 'Changed')
      arguments = { after_id: first.id, recipient_id: @recipient.id, application_id: nil }

      stub_const(ReconcilePendingJob, :BATCH_SIZE, 1) do
        ReconcilePendingJob.expects(:perform_later).with(**arguments).returns(false)
        assert_difference -> { Event.where(action: 'letter_reconciliation_enqueue_failed').count }, 1 do
          ReconcilePendingJob.perform_now(recipient_id: @recipient.id)
        end
      end

      assert_predicate first.reload, :canceled?
      assert_predicate second.reload, :pending?
      event = Event.where(action: 'letter_reconciliation_enqueue_failed').last
      assert_equal @recipient.id, event.metadata['recipient_id']
      assert_equal first.id, event.metadata['after_id']
    end

    private

    def queue(recipient: @recipient, secure_request_form: nil)
      Delivery.queue!(recipient: recipient, application: @application, letter_type: :medical_certification_form,
                      context: @context, secure_request_form: secure_request_form,
                      request_key: SecureRandom.uuid) { StringIO.new('%PDF test letter') }.tap { |item| @items << item }
    end
  end
end
