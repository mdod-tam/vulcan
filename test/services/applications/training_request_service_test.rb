# frozen_string_literal: true

require 'test_helper'

module Applications
  class TrainingRequestServiceTest < ActiveSupport::TestCase
    setup do
      @constituent = create(:constituent)
      @admin = create(:admin)
      @application = create_reviewed_application(user: @constituent)
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    end

    test 'writes training_requested_at for a valid request' do
      NotificationService.stubs(:create_and_deliver!).returns(nil)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert result.success?
      assert_not_nil @application.reload.training_requested_at
    end

    test 'rejects requests outside the service window with a clear message' do
      @application.update!(application_date: 4.years.ago.to_date)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.service_window'), result.message
    end

    test 'rejects duplicate pending request' do
      @application.update!(training_requested_at: 1.hour.ago)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.duplicate_pending'), result.message
    end

    test 'uses constituent locale for duplicate pending request message' do
      @constituent.update!(locale: 'es')
      @application.update!(training_requested_at: 1.hour.ago)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.duplicate_pending', locale: 'es'), result.message
    end

    test 'rejects duplicate request when an active training session exists' do
      create(:training_session, application: @application, trainer: create(:trainer), status: :requested)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.active_session'), result.message
    end

    test 'allows re-request after cancelled session when quota remains' do
      NotificationService.stubs(:create_and_deliver!).returns(nil)
      create(:training_session, :cancelled, application: @application, trainer: create(:trainer))

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert result.success?
      assert_not_nil @application.reload.training_requested_at
    end

    test 'counts only completed sessions against quota' do
      NotificationService.stubs(:create_and_deliver!).returns(nil)
      trainer = create(:trainer)

      create(:training_session, :completed, application: @application, trainer: trainer)
      create(:training_session, :completed, application: @application, trainer: trainer)
      create(:training_session, :cancelled, application: @application, trainer: trainer)
      create(:training_session, application: @application, trainer: trainer, status: :no_show, scheduled_for: 1.day.ago, no_show_notes: 'missed it')

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert result.success?
    end

    test 'rejects request when completed session quota is exhausted' do
      trainer = create(:trainer)
      create_list(:training_session, 3, :completed, application: @application, trainer: trainer)

      result = TrainingRequestService.new(application: @application, current_user: @constituent).call

      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.quota_exhausted'), result.message
    end

    private

    def create_reviewed_application(user:)
      application = create(:application, skip_proofs: true, user: user, status: :in_progress)
      attach_required_proofs(application)
      application.update_columns(
        application_date: 2.years.ago.to_date,
        status: Application.statuses[:approved],
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved],
        updated_at: Time.current
      )
      application.reload
    end

    def attach_required_proofs(application)
      application.income_proof.attach(
        io: StringIO.new('income proof content'),
        filename: 'income.pdf',
        content_type: 'application/pdf'
      )
      application.residency_proof.attach(
        io: StringIO.new('residency proof content'),
        filename: 'residency.pdf',
        content_type: 'application/pdf'
      )
    end
  end
end
