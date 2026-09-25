# frozen_string_literal: true

require 'test_helper'

module Applications
  class AutosaveOrderingConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    setup do
      @user = create(:constituent, vision_disability: true, hearing_disability: false)
      @context = SecureRandom.uuid
    end

    teardown do
      cleanup_duplicate_review_test_data!(@user)
    end

    test 'a blocked older autosave observes the newer revision after its transaction commits' do
      draft = create(:application, :draft, user: @user, household_size: 2)
      newer, older = contend(
        holder: -> { save_field(application_id: draft.id, value: '7', revision: 2) },
        contender: -> { save_field(application_id: draft.id, value: '4', revision: 1) }
      )

      assert newer[:success], newer.inspect
      assert_equal 'saved', newer[:outcome]
      assert_superseded(older, application_id: draft.id)
      assert_equal 7, draft.reload.household_size
      assert_equal 'household_size', draft.last_visited_step
      assert_equal 1, Application.where(user_id: @user.id).count
    end

    test 'a blocked older autosave observes the full form boundary after Save Application commits' do
      draft = create(:application, :draft, user: @user, household_size: 2)
      saved, older = contend(
        holder: -> { save_form(application_id: draft.id, value: 7, revision: 2) },
        contender: -> { save_field(application_id: draft.id, value: '4', revision: 1) }
      )

      assert saved.success?, saved.error_messages.inspect
      assert_superseded(older, application_id: draft.id)
      assert_equal 7, draft.reload.household_size
      assert_equal 'draft', draft.status
      assert_nil draft.last_visited_step, 'the superseded autosave must not write draft progress'
      assert_equal 1, Event.where(action: 'application_updated', auditable: draft).count
    end

    test 'a first full form Save waiting behind first autosave resumes its newly committed draft' do
      autosaved, saved = contend(
        holder: -> { save_field(value: '4', revision: 1) },
        contender: -> { save_form(value: 7, revision: 2) }
      )

      assert autosaved[:success], autosaved.inspect
      assert saved.success?, saved.error_messages.inspect
      draft = Application.where(user_id: @user.id).sole
      assert_equal draft.id, autosaved[:application_id]
      assert_equal draft.id, saved.application.id
      assert_equal 7, draft.household_size
      assert_equal 'draft', draft.status
      assert_equal 1, Event.where(action: 'application_created', auditable: draft).count
    end

    test 'a first autosave waiting behind first full form Save resumes its draft and respects its boundary' do
      saved, older = contend(
        holder: -> { save_form(value: 7, revision: 2) },
        contender: -> { save_field(value: '4', revision: 1) }
      )

      assert saved.success?, saved.error_messages.inspect
      draft = Application.where(user_id: @user.id).sole
      assert_equal draft.id, saved.application.id
      assert_superseded(older, application_id: draft.id)
      assert_equal 7, draft.household_size
      assert_equal 'draft', draft.status
      assert_nil draft.last_visited_step
      assert_equal 1, Event.where(action: 'application_created', auditable: draft).count
    end

    private

    # Hold the real writer's transaction open until PostgreSQL confirms that the other writer
    # is waiting on it. Both services then finish normally, on separate database connections.
    def contend(holder:, contender:)
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_result = nil
      contender_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          holder_result = holder.call
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        contender_result = contender.call
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid, release_queue: release_holder,
        holder_thread: holder_thread, contender_thread: contender_thread
      )
      [holder_result, contender_result]
    ensure
      release_holder << true
      [holder_thread, contender_thread].compact.each do |thread|
        reap_thread(thread, timeout: 10, suppress_errors: true)
      end
    end

    def save_field(value:, revision:, application_id: nil)
      AutosaveService.new(current_user: User.find(@user.id), params: {
                            id: application_id, field_name: 'application[household_size]', field_value: value,
                            autosave_context: @context, autosave_revision: revision
                          }).call
    end

    def save_form(value:, revision:, application_id: nil)
      form = ApplicationForm.new(
        current_user: User.find(@user.id),
        application: application_id ? Application.find(application_id) : nil,
        params: {
          application: {
            annual_income: '50000', household_size: value, vision_disability: true,
            terms_accepted: true, information_verified: true, medical_release_authorized: true,
            medical_provider_attributes: { name: 'Test Provider', phone: '2025550123', email: 'provider@example.com' }
          },
          save_draft: 'Save Application', autosave_context: @context, autosave_revision: revision
        }.with_indifferent_access
      )
      ApplicationCreator.call(form)
    end

    def assert_superseded(result, application_id:)
      assert result[:success], result.inspect
      assert_equal 'superseded', result[:outcome]
      assert_equal application_id, result[:application_id]
      assert_equal 1, result[:revision]
      assert_equal 2, result[:current_revision]
      assert_equal 7, result[:value]
    end
  end
end
