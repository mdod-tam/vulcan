# frozen_string_literal: true

require 'test_helper'

class PrintedLetterDeliveryIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    @constituent = create(:constituent, communication_preference: :letter)
    @application = create(:application, user: @constituent)
  end

  teardown do
    Current.reset
  end

  test 'sync secure proof request queues PrintQueueItem when recipient prefers letter' do
    application = create(:application, :in_progress, id_proof_status: :not_reviewed, user: @constituent)
    ApplicationNotificationsMailer.unstub(:proof_requested)

    result = assert_difference('PrintQueueItem.count', 1) do
      Applications::RequestProofResubmission.new(
        application: application,
        actor: @admin,
        proof_type: :id
      ).call
    end

    assert_predicate result, :success?
    secure_request_form = result.data.fetch(:secure_request_forms).first
    assert_predicate secure_request_form, :recipient_channel_letter?

    print_item = PrintQueueItem.last
    assert_equal application.id, print_item.application_id
    assert_equal @constituent.id, print_item.constituent_id
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'paper proof rejection auto-issues resubmission and queues rejected letter type' do
    application = create(:application, :in_progress, income_proof_status: :rejected, user: @constituent)
    ApplicationNotificationsMailer.unstub(:proof_rejected)
    Current.paper_context = true

    proof_review = nil
    assert_difference('PrintQueueItem.count', 1) do
      proof_review = create(
        :proof_review,
        :rejected,
        application: application,
        admin: @admin,
        proof_type: :income,
        rejection_reason: 'Missing income details'
      )
    end

    secure_request_form = SecureRequestForm.where(application: application).order(:created_at).last
    assert_predicate secure_request_form, :recipient_channel_letter?

    print_item = PrintQueueItem.last
    assert_equal 'income_proof_rejected', print_item.letter_type
    assert_equal application.id, print_item.application_id
    assert_equal proof_review.id, application.proof_reviews.where(proof_type: :income, status: :rejected).pick(:id)
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'admin proof rejection via ProofReviewer queues PrintQueueItem for letter-preference voice users' do
    application = create(:application, :in_progress, user: @constituent)
    @constituent.update!(phone_type: :voice)
    application.income_proof.attach(
      io: StringIO.new('income proof content'),
      filename: 'income.pdf',
      content_type: 'application/pdf'
    )
    ApplicationNotificationsMailer.unstub(:proof_rejected)

    assert_difference('PrintQueueItem.count', 1) do
      Applications::ProofReviewer.new(application, @admin).review(
        proof_type: :income,
        status: :rejected,
        rejection_reason: 'Document is not acceptable'
      )
    end

    print_item = PrintQueueItem.last
    assert_equal 'income_proof_rejected', print_item.letter_type
    assert_equal application.id, print_item.application_id
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'email communication preference routes secure proof request to email not SMS or print' do
    @constituent.update!(communication_preference: :email, phone_type: :text)
    application = create(:application, :in_progress, income_proof_status: :not_reviewed, user: @constituent)
    ApplicationNotificationsMailer.unstub(:proof_requested)
    SmsService.expects(:send_message).never

    assert_no_difference('PrintQueueItem.count') do
      result = Applications::RequestProofResubmission.new(
        application: application,
        actor: @admin,
        proof_type: :income
      ).call

      assert_predicate result, :success?
      secure_request_form = result.data.fetch(:secure_request_forms).first
      assert_predicate secure_request_form, :recipient_channel_email?
    end
  end

  test 'paper proof rejection uses communication preference letter over text phone type' do
    @constituent.update!(communication_preference: :letter, phone_type: :text)
    application = create(:application, :in_progress, income_proof_status: :rejected, user: @constituent)
    application.income_proof.purge if application.income_proof.attached?
    ApplicationNotificationsMailer.unstub(:proof_rejected)
    SmsService.expects(:send_message).never
    Current.paper_context = true

    assert_difference('PrintQueueItem.count', 1) do
      create(
        :proof_review,
        :rejected,
        application: application,
        admin: @admin,
        proof_type: :income,
        rejection_reason: 'Missing income details'
      )
    end

    secure_request_form = SecureRequestForm.where(application: application).order(:created_at).last
    assert_predicate secure_request_form, :recipient_channel_letter?

    print_item = PrintQueueItem.last
    assert_equal 'income_proof_rejected', print_item.letter_type
  ensure
    Current.reset
  end

  test 'sync provider info request queues PrintQueueItem when recipient prefers letter' do
    ApplicationNotificationsMailer.unstub(:provider_info_requested)

    result = assert_difference('PrintQueueItem.count', 1) do
      Applications::RequestProviderInfo.new(application: @application, actor: @admin).call
    end

    assert_predicate result, :success?
    secure_request_form = result.data.fetch(:secure_request_forms).first
    assert_predicate secure_request_form, :recipient_channel_letter?

    print_item = PrintQueueItem.last
    assert_equal 'provider_info_requested', print_item.letter_type
    assert_equal @application.id, print_item.application_id
    assert_equal @constituent.id, print_item.constituent_id
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'async account_created notification queues PrintQueueItem after mailer job runs' do
    ApplicationNotificationsMailer.unstub(:account_created)

    assert_difference('PrintQueueItem.count', 1) do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        NotificationService.create_and_deliver!(
          type: :account_created,
          recipient: @constituent,
          actor: @admin,
          notifiable: @constituent,
          channel: :email
        )
      end
    end

    print_item = PrintQueueItem.last
    assert_equal 'account_created', print_item.letter_type
    assert_equal @constituent.id, print_item.constituent_id
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'async direct registration confirmation mailer queues PrintQueueItem after job runs' do
    ApplicationNotificationsMailer.unstub(:registration_confirmation)

    assert_difference('PrintQueueItem.count', 1) do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        ApplicationNotificationsMailer.registration_confirmation(@constituent).deliver_later
      end
    end

    print_item = PrintQueueItem.last
    assert_equal 'registration_confirmation', print_item.letter_type
    assert_equal @constituent.id, print_item.constituent_id
    assert_predicate print_item.pdf_letter, :attached?
  end

  test 'async proof received notification queues PrintQueueItem after mailer job runs' do
    ApplicationNotificationsMailer.unstub(:proof_received)

    assert_difference('PrintQueueItem.count', 1) do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        NotificationService.create_and_deliver!(
          type: :id_proof_attached,
          recipient: @constituent,
          actor: @constituent,
          notifiable: @application,
          metadata: { proof_type: 'id' },
          channel: :email
        )
      end
    end

    print_item = PrintQueueItem.last
    assert_equal @application.id, print_item.application_id
    assert_equal @constituent.id, print_item.constituent_id
    assert_predicate print_item.pdf_letter, :attached?
  end
end
