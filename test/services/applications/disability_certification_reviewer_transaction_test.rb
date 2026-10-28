# frozen_string_literal: true

require 'test_helper'

module Applications
  class DisabilityCertificationReviewerTransactionTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @constituent = create(:constituent)
      @application = create(:application, user: @constituent, disability_certification_status: :requested,
                                          medical_provider_name: 'Dr. Provider', medical_provider_email: 'provider@example.test')
    end

    teardown do
      cleanup_duplicate_review_test_data!(@admin, @constituent)
    end

    test 'paper rejection waits for the outer commit before issuing a secure link or notifying the provider' do
      attempts = []
      RequestCertificationUpload.any_instance.stubs(:call).with do
        assert_not ActiveRecord::Base.current_transaction.open?
        attempts << :secure_request
        true
      end.returns(BaseService::Result.new(success: true, data: { secure_upload_url: 'https://example.test/secure_certification_form?token=test' }))
      MedicalProviderNotifier.any_instance.stubs(:send_certification_rejection_notice).with do |**_arguments|
        assert_not ActiveRecord::Base.current_transaction.open?
        assert @application.reload.disability_certification_status_rejected?
        attempts << :provider
        true
      end.returns(success: false, outcome: :suppressed, tracking_status: :recorded)
      documents = paper_documents

      ActiveRecord::Base.transaction do
        assert documents.call, @paper_errors.inspect
        assert_empty attempts
        assert_empty @paper_warnings
      end

      assert_equal %i[secure_request provider], attempts
      assert @application.reload.disability_certification_status_rejected?
      assert_includes @paper_warnings.join(' '), 'Provider email was not sent because delivery is disabled.'
      assert_equal 1, ApplicationStatusChange.where(application: @application, to_status: 'rejected').count
    end

    test 'outer rollback restores rejection writes and performs no provider or secure-link operation' do
      RequestCertificationUpload.any_instance.expects(:call).never
      MedicalProviderNotifier.any_instance.expects(:send_certification_rejection_notice).never
      before_counts = [ApplicationStatusChange.where(application: @application).count,
                       Notification.where(notifiable: @application).count,
                       @application.proof_reviews.count,
                       Event.where(auditable: @application).count]

      documents = paper_documents
      ActiveRecord::Base.transaction do
        assert documents.call, @paper_errors.inspect
        assert_empty @paper_warnings
        raise ActiveRecord::Rollback
      end

      assert @application.reload.disability_certification_status_requested?
      assert_equal before_counts, [ApplicationStatusChange.where(application: @application).count,
                                   Notification.where(notifiable: @application).count,
                                   @application.proof_reviews.count,
                                   Event.where(auditable: @application).count]
      assert_empty @application.medical_provider_secure_request_forms
    end

    test 'missing rejection notification preserves committed rejection and warns without repeating provider delivery' do
      invalid_notification = Notification.new
      invalid_notification.errors.add(:base, 'Private notification validation failure')
      Notification.expects(:create!).with(has_entries(action: 'disability_certification_rejected', notifiable: @application))
                  .raises(ActiveRecord::RecordInvalid.new(invalid_notification))
      secure_upload_url = 'https://example.test/secure_certification_form?token=test'
      RequestCertificationUpload.any_instance.expects(:call).returns(
        BaseService::Result.new(success: true, data: { secure_upload_url: secure_upload_url })
      )
      mail = stub('certification_rejection_mail')
      mail.stubs(:[]).with('X-PM-Message-Id').returns(stub(value: 'MSG-TRACKING'))
      MedicalProviderMailer.expects(:with).with(
        application: @application, rejection_reason: 'Missing signature', admin: @admin, secure_upload_url: secure_upload_url
      ).returns(stub(certification_rejected: mail))
      EmailDelivery.expects(:deliver_now!).with(mail, context: anything).once.returns(true)
      documents = paper_documents

      assert_no_difference -> { Notification.where(notifiable: @application, action: 'disability_certification_rejected').count } do
        ActiveRecord::Base.transaction do
          assert documents.call, @paper_errors.inspect
          assert_empty @paper_warnings
        end
      end

      assert @application.reload.disability_certification_status_rejected?
      assert_equal 1, ApplicationStatusChange.where(application: @application, to_status: 'rejected').count
      assert_equal 1, Event.where(auditable: @application, action: 'disability_certification_status_changed').count
      review = @application.proof_reviews.find_by!(proof_type: :disability_certification, status: :rejected)
      assert_equal 'Missing signature', review.rejection_reason
      assert_includes @paper_warnings.join(' '), 'Provider email submitted.'
      assert_includes @paper_warnings.join(' '), 'Rejection notification tracking is unavailable; verify provider email before retrying.'
      assert_not_includes @paper_warnings.join(' '), 'Provider email was not sent.'
      assert_not_includes @paper_warnings.join(' '), 'Private notification validation failure'
    end

    test 'a database note failure preserves the paper rejection and attempts provider delivery only after a successful commit' do
      attempts = []
      note_save_attempts = 0
      ApplicationNote.any_instance.stubs(:save!).with do
        note_save_attempts += 1
        ApplicationNote.connection.select_value('SELECT 1 / 0')
        true
      end.returns(true)
      RequestCertificationUpload.any_instance.stubs(:call).with do
        assert_not ActiveRecord::Base.current_transaction.open?
        attempts << [:secure_request, @application.reload.disability_certification_status]
        true
      end.returns(BaseService::Result.new(success: true, data: {}))
      MedicalProviderNotifier.any_instance.stubs(:send_certification_rejection_notice).with do |**_arguments|
        assert_not ActiveRecord::Base.current_transaction.open?
        attempts << [:provider, @application.reload.disability_certification_status]
        true
      end.returns(success: true, outcome: :submitted, tracking_status: :recorded)
      documents = paper_documents(notes: 'Please add a signature')

      assert_difference -> { ApplicationStatusChange.where(application: @application, to_status: 'rejected').count }, 1 do
        assert_difference -> { Event.where(auditable: @application, action: 'disability_certification_status_changed').count }, 1 do
          assert_no_difference -> { ApplicationNote.where(application: @application).count } do
            ActiveRecord::Base.transaction do
              assert documents.call, @paper_errors.inspect
              assert_empty attempts
            end
            assert @application.reload.disability_certification_status_rejected?, "Post-commit attempts: #{attempts.inspect}"
          end
        end
      end

      assert_equal [[:secure_request, 'rejected'], [:provider, 'rejected']], attempts
      assert_includes @paper_warnings.join(' '), 'The rejection note could not be saved.'
      assert_includes @paper_warnings.join(' '), 'Provider email submitted.'
      assert_equal 1, note_save_attempts
    end

    private

    def paper_documents(notes: nil)
      @paper_errors = []
      @paper_warnings = []
      params = {
        disability_certification_action: 'rejected', disability_certification_rejection_reason: 'other',
        disability_certification_custom_rejection_reason: 'Missing signature',
        disability_certification_rejection_notes: notes
      }.with_indifferent_access
      PaperDocumentDispositions.new(application: @application, admin: @admin, params: params,
                                    errors: @paper_errors, warnings: @paper_warnings)
    end
  end
end
