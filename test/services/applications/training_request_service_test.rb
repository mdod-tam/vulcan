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

    test 'current managing guardian can request training through the application authorization boundary' do
      manager = create(:constituent)
      create(:guardian_relationship, guardian_user: manager, dependent_user: @constituent)
      @application.update!(managing_guardian: manager)

      result = TrainingRequestService.new(application: @application, current_user: manager).call

      assert result.success?, result.message
      assert_not_nil @application.reload.training_requested_at
      event = Event.find_by!(auditable: @application, action: 'training_session_requested')
      assert_equal manager.id, event.user_id
      assert_equal @constituent.id, event.metadata['constituent_id']
    end

    test 'another related guardian and the former manager cannot request training' do
      manager = create(:constituent)
      other_guardian = create(:constituent)
      [manager, other_guardian].each do |guardian|
        create(:guardian_relationship, guardian_user: guardian, dependent_user: @constituent)
      end
      @application.update!(managing_guardian: manager)
      assert_no_difference -> { Event.where(auditable: @application, action: 'training_session_requested').count } do
        result = TrainingRequestService.new(application: @application, current_user: other_guardian).call
        assert_not result.success?
        assert_equal I18n.t('applications.training_requests.messages.ineligible'), result.message
      end
      assert_nil @application.reload.training_requested_at

      @application.update!(managing_guardian: other_guardian)
      result = TrainingRequestService.new(application: @application, current_user: manager).call
      assert_not result.success?
      assert_equal I18n.t('applications.training_requests.messages.ineligible'), result.message
      assert_nil @application.reload.training_requested_at
    end

    private

    def create_reviewed_application(user:)
      create(:application, :approved, :with_all_proofs, user: user, application_date: 2.years.ago.to_date)
    end
  end
end
