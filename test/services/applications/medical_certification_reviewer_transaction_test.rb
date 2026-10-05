# frozen_string_literal: true

require 'test_helper'

module Applications
  class MedicalCertificationReviewerTransactionTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @constituent = create(:constituent)
      @application = create(:application, user: @constituent, medical_certification_status: :requested,
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
        assert @application.reload.medical_certification_status_rejected?
        attempts << :provider
        true
      end.returns(success: false, outcome: :suppressed, tracking_status: :recorded)
      paper = PaperApplicationService.new(params: {}, admin: @admin)
      paper.instance_variable_set(:@application, @application)

      ActiveRecord::Base.transaction do
        result = paper.send(:reject_medical_certification_via_reviewer,
                            selected_reason: 'other', custom_reason: 'Missing signature', notes: nil)
        assert result[:success]
        assert_equal :deferred, result[:provider_delivery][:outcome]
        assert_empty attempts
        assert_nil paper.warning_message
      end

      assert_equal %i[secure_request provider], attempts
      assert @application.reload.medical_certification_status_rejected?
      assert_includes paper.warning_message, 'Provider email was not sent because delivery is disabled.'
      assert_equal 1, ApplicationStatusChange.where(application: @application, to_status: 'rejected').count
    end

    test 'outer rollback restores rejection writes and performs no provider or secure-link operation' do
      RequestCertificationUpload.any_instance.expects(:call).never
      MedicalProviderNotifier.any_instance.expects(:send_certification_rejection_notice).never
      before_counts = [ApplicationStatusChange.where(application: @application).count,
                       Notification.where(notifiable: @application).count,
                       @application.proof_reviews.count,
                       Event.where(auditable: @application).count]

      ActiveRecord::Base.transaction do
        result = MedicalCertificationReviewer.new(@application, @admin).reject(rejection_reason: 'Missing signature')
        assert result.success?
        assert_equal :deferred, result.data[:provider_delivery][:outcome]
        raise ActiveRecord::Rollback
      end

      assert @application.reload.medical_certification_status_requested?
      assert_equal before_counts, [ApplicationStatusChange.where(application: @application).count,
                                   Notification.where(notifiable: @application).count,
                                   @application.proof_reviews.count,
                                   Event.where(auditable: @application).count]
      assert_empty @application.medical_provider_secure_request_forms
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
        attempts << [:secure_request, @application.reload.medical_certification_status]
        true
      end.returns(BaseService::Result.new(success: true, data: {}))
      MedicalProviderNotifier.any_instance.stubs(:send_certification_rejection_notice).with do |**_arguments|
        assert_not ActiveRecord::Base.current_transaction.open?
        attempts << [:provider, @application.reload.medical_certification_status]
        true
      end.returns(success: true, outcome: :submitted, tracking_status: :recorded)
      paper = PaperApplicationService.new(params: {}, admin: @admin)
      paper.instance_variable_set(:@application, @application)

      assert_difference -> { ApplicationStatusChange.where(application: @application, to_status: 'rejected').count }, 1 do
        assert_difference -> { Event.where(auditable: @application, action: 'medical_certification_status_changed').count }, 1 do
          assert_no_difference -> { ApplicationNote.where(application: @application).count } do
            ActiveRecord::Base.transaction do
              result = paper.send(:reject_medical_certification_via_reviewer,
                                  selected_reason: 'other', custom_reason: 'Missing signature', notes: 'Please add a signature')
              assert result[:success]
              assert_empty attempts
            end
            assert @application.reload.medical_certification_status_rejected?, "Post-commit attempts: #{attempts.inspect}"
          end
        end
      end

      assert_equal [[:secure_request, 'rejected'], [:provider, 'rejected']], attempts
      assert_includes paper.warning_message, 'The rejection note could not be saved.'
      assert_includes paper.warning_message, 'Provider email submitted.'
      assert_equal 1, note_save_attempts
    end
  end
end
