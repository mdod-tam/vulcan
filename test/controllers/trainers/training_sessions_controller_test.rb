# frozen_string_literal: true

require 'test_helper'

module Trainers
  class TrainingSessionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Policy.stubs(:max_training_sessions).returns(5)
      @trainer = create(:trainer)
      @admin = create(:admin)
      @application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
      @session = create(:training_session, :scheduled, application: @application, trainer: @trainer,
                                                       created_at: 2.days.ago, internal_notes: 'Private preparation retained', scheduled_for: 1.day.from_now.change(sec: 0))
      @product = create(:product)
      @other_trainer = create(:trainer)
      @other_session = create(:training_session, :scheduled, trainer: @other_trainer)
      sign_in_for_controller_test(@trainer)
    end

    test 'current trainer sees coordinating contact preparation and named outcome controls' do
      get trainers_training_session_path(@session)

      assert_response :success
      assert_select '#preparation-heading', text: 'Preparation and coordinating contact'
      assert_select "a[href='mailto:#{@application.user.email}']"
      assert_select "a[href='#{admin_application_path(@application)}']", count: 0
      assert_select '#training-outcome option[value=complete]'
      assert_select '#training-outcome option[value=cancel]'
      assert_select '#training-outcome option[value=reschedule]'
      assert_select '#training-outcome option[value=no_show]', count: 0
      assert_select "form[action='#{schedule_additional_trainers_training_session_path(@session)}']", count: 0
      assert_select '#complete_internal_notes', text: 'Private preparation retained'
      assert_select_value '#complete_product_trained_on_id', ''
      assert_select '#complete_completed_at[value]', count: 0
      assert_select '#complete_duration_hours[aria-describedby=duration_hours_hint]'
      assert_select '#duration_hours_hint', text: 'Enter total time spent training, in hours.'
      assert_select 'h2#session-actions-heading', text: 'What happened?'
      assert_select '[data-training-outcome-target=status][role=status][aria-live=polite][aria-atomic=true]', text: ''
      assert_select 'h2#training-capacity-heading', text: 'Training session allowance'
      assert_operator response.body.index('id="session-actions"'), :<, response.body.index('id="preparation-heading"')
      assert_select '#complete_completed_at[aria-describedby=complete-time-help]'
      assert_select '#complete-time-help', text: /format displayed by your browser.*Eastern Time/m
      assert_select 'label[for=complete_constituent_summary] span', text: '(required)'
      assert_select '#complete_constituent_summary[aria-describedby=complete-summary-help]'
      assert_select '#complete_internal_notes[aria-describedby=complete-observations-help]'
    end

    test 'completion defaults use recorded appointment details but rejected blanks still win' do
      @session.update!(product_trained_on: @product, duration_hours: '1.5')
      travel_to(@session.scheduled_for + 1.hour) do
        sign_in_for_controller_test(@trainer)
        get trainers_training_session_path(@session)

        assert_response :success
        assert_input_value '#complete_completed_at', @session.scheduled_for.strftime('%Y-%m-%dT%H:%M')
        assert_select_value '#complete_product_trained_on_id', @product.id.to_s
        assert_select '#complete_duration_hours' do |fields|
          assert_equal BigDecimal('1.5'), BigDecimal(fields.sole['value'])
        end

        attempted = completion_params.merge(completed_at: '', product_trained_on_id: '', duration_hours: '')
        post complete_trainers_training_session_path(@session), params: attempted
        assert_response :unprocessable_content
        assert_completion_values(attempted)
        assert_select_value '#complete_product_trained_on_id', ''
      end
    end

    test 'same product guidance has placement-specific unique headings and landmark names' do
      report = new_session(:completed, product_trained_on: @product)
      create(:product_resource, product: @product, title: 'Practice guide')
      purchase = create(:voucher_transaction, voucher: create(:voucher, application: report.application))
      purchase.voucher_transaction_products.create!(product: @product, quantity: 1)
      get trainers_training_session_path(report)

      assert_response :success
      document = response.parsed_body
      ids = document.css('[id]').pluck('id')
      assert_equal ids.uniq, ids
      regions = document.css('section[aria-labelledby]')
                        .select { |node| node['aria-labelledby'].include?('known-products-heading') || node['aria-labelledby'].include?('completed-trained-product-heading') }
      assert_equal 2, regions.length
      names = regions.map do |region|
        region['aria-labelledby'].split.map { |id| document.at_css("##{id}").text.strip }.join(' ')
      end
      assert_equal names.uniq, names
      assert(names.all? { |name| name.include?(@product.name) })
      assert_select 'section[aria-labelledby~="known-products-heading"] h4', text: /Practice|Guides for/
      assert_select 'section[aria-labelledby~="completed-trained-product-heading"] h3', text: /Guides for/
      assert_select 'dd[lang=en]', text: report.constituent_summary
    end

    test 'older reports do not claim that another appointment is unavailable' do
      report = new_session(:completed)
      create(:training_session, :requested, application: report.application, trainer: @trainer, created_at: Time.current)
      get trainers_training_session_path(report)

      assert_response :success
      assert_not_includes response.body, 'Another appointment is unavailable'
      assert_not_includes response.body, I18n.t('training_rules.close_open_first')
      assert_select 'input[value="Schedule another session"]', count: 0
    end

    test 'guardian-coordinated preparation uses the applications managing guardian and proposed summary language' do
      guardian = create(:constituent, locale: 'es')
      applicant = create(:constituent, dependent_email: guardian.email, dependent_phone: guardian.phone)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
      application = create(:application, :approved, :with_all_proofs, user: applicant, managing_guardian: guardian,
                                                                      application_date: Date.current, assigned_trainer: @trainer)
      session = create(:training_session, :scheduled, application: application, trainer: @trainer)

      get trainers_training_session_path(session)

      assert_response :success
      assert_includes response.body, guardian.full_name
      assert_select "a[href='mailto:#{guardian.email}']"
      assert_select "a[href='mailto:#{applicant.email}']", count: 0
      assert_select '#complete_summary_locale option[value=es][selected]'
      assert_includes response.body, 'Spanish'
    end

    test 'requested appointments offer scheduling and cancellation with a blank agreed date' do
      session = new_session(:requested)
      get trainers_training_session_path(session)

      assert_response :success
      assert_select "form[action='#{schedule_trainers_training_session_path(session)}']"
      assert_select "form[action='#{cancel_trainers_training_session_path(session)}']"
      assert_select '#schedule_scheduled_for[required]'
      assert_select '#schedule_scheduled_for[value]', count: 0
      assert_select 'details:not([open]) summary', text: 'Cancel this unscheduled appointment'
      assert_select "form[action='#{cancel_trainers_training_session_path(session)}'][data-turbo-confirm]"
      assert_select '#schedule_scheduled_for[aria-describedby=schedule-time-help]'
      assert_select 'h2#session-actions-heading', text: 'Session actions'
      assert_select "form[action='#{complete_trainers_training_session_path(session)}']", count: 0
    end

    test 'admin oversight is read-only and another trainer has no report or contact access' do
      sign_in_for_controller_test(@admin)
      get trainers_training_session_path(@session)
      assert_response :success
      assert_includes response.body, 'This view is read-only.'
      assert_select "form[action='#{complete_trainers_training_session_path(@session)}']", count: 0
      assert_select '#preparation-heading'

      sign_in_for_controller_test(@other_trainer)
      get trainers_training_session_path(@session)
      assert_response :not_found
      assert_not_includes response.body, @application.user.email
    end

    test 'historical author retains their report without current contact preparation or newer reports' do
      report = new_session(:completed, internal_notes: 'Own authored observations', constituent_summary: 'Own shared summary')
      application = report.application
      contact_email = application.user.email
      assert application.unassign_trainer!(actor: @admin)
      assert application.assign_trainer!(@other_trainer, actor: @admin)
      newer = create(:training_session, :completed, application: application, trainer: @other_trainer,
                                                    internal_notes: 'NEW TRAINER REPORT SENTINEL', constituent_summary: 'New shared summary')
      cancelled = create(:training_session, :cancelled, application: application, trainer: @other_trainer,
                                                        cancellation_reason: 'NEW CANCELLATION SENTINEL')
      create(:notification, notifiable: report, recipient: application.user, action: 'training_completed', delivery_status: :error)

      get trainers_training_session_path(report)

      assert_response :success
      assert_includes response.body, 'Own authored observations'
      assert_includes response.body, 'Own shared summary'
      assert_includes response.body, 'read-only access to this authored report'
      assert_not_includes response.body, contact_email
      assert_not_includes response.body, newer.internal_notes
      assert_not_includes response.body, cancelled.cancellation_reason
      assert_select '#preparation-heading', count: 0
      assert_select '#activity-history-heading', count: 0
      assert_select "[aria-label='#{I18n.t('delivery_visibility.history')}']", count: 0
      assert_select '[aria-label="Training capacity"]', count: 0
      assert_select 'form[action*="training_sessions"]', count: 0
      assert_select "a[href='#{trainers_training_session_path(newer)}']", count: 0
      assert_select 'h2', text: 'Previous completed reports', count: 0

      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        post schedule_additional_trainers_training_session_path(report), params: { scheduled_for: 2.days.from_now }
      end
      assert_redirected_to trainers_training_session_path(report)
      assert_equal I18n.t('trainers.training_sessions.flash.assigned_trainer_only'), flash[:alert]
      follow_redirect!
      assert_select '[data-testid=flash-alert][role=alert][aria-live=assertive]', text: I18n.t('trainers.training_sessions.flash.assigned_trainer_only')
    end

    test 'early visit completion stores deliberate shared content and actual occurrence separately from submission' do
      actual_time = 2.hours.ago.change(sec: 0)
      assert_difference "Event.where(action: 'training_completed').count", 1 do
        post complete_trainers_training_session_path(@session), params: completion_params.merge(completed_at: actual_time)
      end

      assert_response :see_other
      assert_redirected_to trainers_training_session_path(@session)
      @session.reload
      assert @session.status_completed?
      assert_equal actual_time, @session.completed_at
      assert_operator @session.report_submitted_at, :>, @session.completed_at
      assert_operator @session.scheduled_for, :>, @session.completed_at
      assert_equal 'Shared practice and next steps', @session.constituent_summary
      assert_equal 'es', @session.summary_locale
      assert_equal 'Private report observations', @session.internal_notes
      assert_equal @product.id, @session.product_trained_on_id
      assert_equal BigDecimal('1.25'), @session.duration_hours
      assert_equal @trainer.id, @application.reload.assigned_trainer_id
      event = Event.find_by!(action: 'training_completed', auditable: @session)
      assert_not_includes event.metadata.to_json, 'Private report observations'
      assert_not_includes event.metadata.to_json, 'Shared practice and next steps'
      follow_redirect!
      assert_select '[data-testid=flash-notice][role=status][aria-live=polite][aria-atomic=true]', text: 'Training session completed successfully.'
      assert_select '#activity-history-heading + div td', text: /Product: #{Regexp.escape(@product.name)}/
      assert_select '#activity-history-heading + div td', text: /Product ID:/, count: 0
    end

    test 'invalid completion retains all independent fields then unchanged and corrected retries remain truthful' do
      attempted = completion_params.merge(completed_at: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'),
                                          duration_hours: '1.75', internal_notes: 'Attempted private notes',
                                          constituent_summary: 'Attempted authored summary')
      2.times do
        assert_no_difference 'Event.count' do
          post complete_trainers_training_session_path(@session), params: attempted
        end
        assert_response :unprocessable_content
        assert @session.reload.status_scheduled?
        assert_nil @session.report_submitted_at
        assert_completion_values(attempted)
        assert_select '#complete-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
        assert_select '#complete_completed_at[aria-invalid=true]'
        assert_select 'select#training-outcome option[value=complete][selected]'
        assert_select '[data-training-outcome-target=status]', text: ''
      end

      post complete_trainers_training_session_path(@session),
           params: attempted.merge(completed_at: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'), internal_notes: '')
      assert_response :see_other
      assert @session.reload.status_completed?
      assert_equal '', @session.internal_notes
      assert_equal 'Attempted authored summary', @session.constituent_summary
    end

    test 'completion preserves deliberately blank required inputs without substituting report language or product' do
      attempted = completion_params.merge(completed_at: '', product_trained_on_id: '', duration_hours: '',
                                          internal_notes: '', constituent_summary: '', summary_locale: '')
      post complete_trainers_training_session_path(@session), params: attempted

      assert_response :unprocessable_content
      assert_completion_values(attempted)
      assert_select_value '#complete_summary_locale', ''
      assert_select_value '#complete_product_trained_on_id', ''
      assert_equal 'Private preparation retained', @session.reload.internal_notes
      assert_nil @session.constituent_summary
    end

    test 'missing trained product links its association error to the submitted product control' do
      post complete_trainers_training_session_path(@session), params: completion_params.merge(product_trained_on_id: '')

      assert_response :unprocessable_content
      assert_select '#complete_product_trained_on_id[aria-invalid=true]'
      assert_select '#complete-errors a[href="#complete_product_trained_on_id"]'
      assert @session.reload.status_scheduled?
      assert_nil @session.product_trained_on_id
    end

    test 'completion with omitted private notes retains preparation and cannot accept a supplied submission timestamp' do
      post complete_trainers_training_session_path(@session), params: completion_params.except(:internal_notes).merge(report_submitted_at: 5.years.ago)

      assert_response :see_other
      @session.reload
      assert_equal 'Private preparation retained', @session.internal_notes
      assert_operator @session.report_submitted_at, :>, 1.minute.ago
    end

    test 'new appointments accept only scheduling fields and preserve invalid submitted date location and private notes' do
      session = new_session(:requested)
      attempted = { scheduled_for: 1.day.ago.strftime('%Y-%m-%dT%H:%M'), location: 'Attempted community room', internal_notes: 'Attempted preparation' }
      2.times do
        post schedule_trainers_training_session_path(session), params: attempted
        assert_response :unprocessable_content
        assert_input_value '#schedule_scheduled_for', attempted[:scheduled_for]
        assert_input_value '#schedule_location', attempted[:location]
        assert_select '#schedule_internal_notes', text: attempted[:internal_notes]
        assert session.reload.status_requested?
      end
      agreed = 2.days.from_now.strftime('%Y-%m-%dT%H:%M')
      post schedule_trainers_training_session_path(session), params: attempted.merge(scheduled_for: agreed, location: '', internal_notes: '', status: 'completed', constituent_summary: 'Forged summary')

      assert_response :see_other
      assert session.reload.status_scheduled?
      assert_equal '', session.location
      assert_equal '', session.internal_notes
      assert_nil session.constituent_summary
    end

    test 'requested cancellation records the named initiator and preserves private preparation' do
      session = new_session(:requested, internal_notes: 'Private scheduling history')
      assert_difference "Event.where(action: 'training_cancelled').count", 1 do
        post cancel_trainers_training_session_path(session), params: { cancellation_reason: 'Constituent requested cancellation', cancellation_initiator: 'constituent' }
      end

      assert_response :see_other
      assert session.reload.status_cancelled?
      assert session.cancellation_initiator_constituent?
      assert_equal 'Private scheduling history', session.internal_notes
      assert_equal @trainer.id, session.application.reload.assigned_trainer_id
      event = Event.find_by!(action: 'training_cancelled', auditable: session)
      assert_equal @trainer.id, event.user_id
      assert_equal 'constituent', event.metadata['cancellation_initiator']
      assert_not_includes event.metadata.to_json, session.cancellation_reason
    end

    test 'invalid cancellation preserves its reason and initiator for retry' do
      post cancel_trainers_training_session_path(@session), params: { cancellation_reason: '', cancellation_initiator: 'program' }
      assert_response :unprocessable_content
      assert_select '#cancel_cancellation_reason[aria-invalid=true]', text: ''
      assert_select '#cancel-errors a[href="#cancel_cancellation_reason"]'
      assert_select '#cancel_cancellation_initiator option[value=program][selected]'
      assert @session.reload.status_scheduled?

      post cancel_trainers_training_session_path(@session), params: { cancellation_reason: 'Program unavailable', cancellation_initiator: 'program' }
      assert_response :see_other
      assert @session.reload.cancellation_initiator_program?
    end

    test 'missing cancellation initiator and reschedule reason point the error summary to their controls' do
      post cancel_trainers_training_session_path(@session), params: { cancellation_reason: 'Participant requested cancellation', cancellation_initiator: '' }
      assert_response :unprocessable_content
      assert_select '#cancel_cancellation_initiator[aria-invalid=true]'
      assert_select '#cancel-errors a[href="#cancel_cancellation_initiator"]'
      assert_select '#cancel_cancellation_reason', text: 'Participant requested cancellation'
      assert @session.reload.status_scheduled?

      post reschedule_trainers_training_session_path(@session), params: { scheduled_for: 3.days.from_now, location: 'Attempted room', reschedule_reason: '' }
      assert_response :unprocessable_content
      assert_select '#reschedule_reschedule_reason[aria-invalid=true]'
      assert_select '#reschedule-errors a[href="#reschedule_reschedule_reason"]'
      assert_input_value '#reschedule_location', 'Attempted room'
      assert @session.reload.status_scheduled?

      post reschedule_trainers_training_session_path(@session), params: { scheduled_for: @session.scheduled_for.strftime('%Y-%m-%dT%H:%M'), reschedule_reason: 'Same agreement submitted again' }
      assert_response :unprocessable_content
      assert_select '#reschedule_scheduled_for[aria-invalid=true]'
      assert_select '#reschedule-errors a[href="#reschedule_scheduled_for"]'
    end

    test 'new outcome validation uses the trainers supported viewer language' do
      @trainer.update!(locale: 'es')
      post no_show_trainers_training_session_path(@session), params: { no_show_notes: 'Demasiado pronto' }

      assert_response :unprocessable_content
      assert_includes response.body, 'Registre una ausencia solo después de la hora programada de la cita.'
      assert @session.reload.status_scheduled?
    end

    test 'passed appointments offer no-show and closing while an early no-show and stale terminal rewrite fail' do
      post no_show_trainers_training_session_path(@session), params: { no_show_notes: 'Too early' }
      assert_response :unprocessable_content
      assert @session.reload.status_scheduled?

      travel_to 2.days.from_now do
        sign_in_for_controller_test(@trainer)
        get trainers_training_session_path(@session)
        assert_select '#training-outcome option[value=no_show]'
        assert_select '#training-outcome option[value=reschedule]'
        post no_show_trainers_training_session_path(@session), params: { no_show_notes: '' }
        assert_response :unprocessable_content
        assert_select '#no_show_no_show_notes', text: ''
        post no_show_trainers_training_session_path(@session), params: { no_show_notes: 'Private absence reason' }
        assert_response :see_other
      end
      assert @session.reload.status_no_show?
      assert_equal 'Private preparation retained', @session.internal_notes
      assert_no_difference 'Event.count' do
        post complete_trainers_training_session_path(@session), params: completion_params
      end
      assert_response :unprocessable_content
      assert @session.reload.status_no_show?
    end

    test 'rescheduling requires a different future agreed date and retains rejected submitted state' do
      attempted = { scheduled_for: @session.scheduled_for.strftime('%Y-%m-%dT%H:%M'), location: 'Attempted new location', reschedule_reason: 'Constituent requested a change' }
      attempted[:scheduled_for] = ''
      2.times do
        post reschedule_trainers_training_session_path(@session), params: attempted
        assert_response :unprocessable_content
        assert_input_value '#reschedule_scheduled_for', ''
        assert_input_value '#reschedule_location', attempted[:location]
        assert_select '#reschedule_reschedule_reason', text: attempted[:reschedule_reason]
      end
      post reschedule_trainers_training_session_path(@session), params: attempted.merge(scheduled_for: 3.days.from_now.strftime('%Y-%m-%dT%H:%M'), location: '')
      assert_response :see_other
      assert_equal '', @session.reload.location
      assert_equal 'Private preparation retained', @session.internal_notes
      assert_equal attempted[:reschedule_reason], @session.reschedule_reason
    end

    test 'additional appointments start only from the current latest completed outcome and preserve invalid fields' do
      assert_no_difference 'TrainingSession.count' do
        post schedule_additional_trainers_training_session_path(@session), params: { scheduled_for: 2.days.from_now }
      end
      assert_response :unprocessable_content
      report = new_session(:completed)
      get trainers_training_session_path(report)
      assert_select '#schedule_additional_scheduled_for[value]', count: 0
      attempted = { scheduled_for: '', location: 'Follow-on location', internal_notes: 'Follow-on private notes' }
      2.times do
        post schedule_additional_trainers_training_session_path(report), params: attempted
        assert_response :unprocessable_content
        assert_input_value '#schedule_additional_scheduled_for', ''
        assert_input_value '#schedule_additional_location', attempted[:location]
        assert_select '#schedule_additional_internal_notes', text: attempted[:internal_notes]
      end
      assert_difference 'TrainingSession.count', 1 do
        post schedule_additional_trainers_training_session_path(report), params: attempted.merge(scheduled_for: 3.days.from_now, internal_notes: '')
      end
      created = report.application.training_sessions.assigned_or_scheduled.sole
      assert_redirected_to trainers_training_session_path(created)
      assert_equal '', created.internal_notes
      assert report.reload.status_completed?
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        post schedule_additional_trainers_training_session_path(report), params: { scheduled_for: 4.days.from_now }
      end
      assert_response :unprocessable_content
    end

    test 'a stale form overtaken by removal is denied after locked recheck without rendering contact details' do
      constructor = ::TrainingSessions::CompleteService.method(:new)
      remove_before_service = lambda do |*arguments|
        assert @application.unassign_trainer!(actor: @admin)
        constructor.call(*arguments)
      end

      ::TrainingSessions::CompleteService.stub(:new, remove_before_service) do
        post complete_trainers_training_session_path(@session), params: completion_params
      end

      assert_redirected_to trainers_training_sessions_path
      assert_not_includes response.body, @application.user.email
      assert @session.reload.status_cancelled?
      assert_nil @session.constituent_summary
      assert_nil @application.reload.assigned_trainer_id
      assert_not Event.exists?(action: 'training_completed', auditable: @session)
    end

    test 'generic status creation edit and destruction routes are absent' do
      [[:post, "/trainers/training_sessions/#{@session.id}/update_status"],
       [:patch, "/trainers/training_sessions/#{@session.id}"],
       [:post, '/trainers/training_sessions'],
       [:get, "/trainers/training_sessions/#{@session.id}/edit"],
       [:delete, "/trainers/training_sessions/#{@session.id}"]].each do |method, path|
        assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(path, method: method) }
      end
    end

    test 'named routes reject another trainers session without changing either application' do
      before = @other_session.attributes
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        post complete_trainers_training_session_path(@other_session), params: completion_params
        assert_response :not_found
        post cancel_trainers_training_session_path(@other_session), params: { cancellation_reason: 'Forged cancellation' }
        assert_response :not_found
      end
      assert_equal before, @other_session.reload.attributes
      assert @session.reload.status_scheduled?
    end

    test 'filtered lists preserve trainer isolation while admins can select a trainer' do
      completed = new_session(:completed, duration_hours: 2.5)
      get trainers_training_sessions_path(status: 'scheduled', scope: 'all', trainer_id: @other_trainer.id)
      assert_response :success
      assert_equal [@session.id], assigns(:training_sessions).pluck(:id)
      assert_equal 'mine', assigns(:current_scope)
      assert_nil assigns(:trainer_filter)

      get completed_trainers_training_sessions_path
      assert_response :success
      assert_equal [completed.id], assigns(:training_sessions).pluck(:id)
      assert_includes response.body, 'Duration: 2.5 hours'

      sign_in_for_controller_test(@admin)
      get filtered_trainers_training_sessions_path(scope: 'all', status: 'scheduled')
      assert_response :success
      assert_includes assigns(:training_sessions).pluck(:id), @session.id
      assert_includes assigns(:training_sessions).pluck(:id), @other_session.id
      get filtered_trainers_training_sessions_path(scope: 'all', trainer_id: @trainer.id)
      assert_response :success
      assert_equal [@session.id, completed.id].sort, assigns(:training_sessions).pluck(:id).sort
      assert_equal @trainer.id, assigns(:trainer_filter).id
    end

    test 'status filters identify the selected filter as current without describing it as a page' do
      { nil => 'All', 'requested' => 'Needs Scheduling', 'scheduled' => 'Scheduled', 'completed' => 'Completed',
        'needs_followup' => 'Needs Follow-up', 'cancelled' => 'Needs Follow-up', 'no_show' => 'Needs Follow-up' }.each do |status, label|
        get trainers_training_sessions_path(status: status)

        assert_response :success
        assert_select '[role=group][aria-labelledby=training-status-filter-label]', count: 1 do
          assert_select 'a[aria-current=true]', text: label, count: 1
          assert_select 'a[aria-current=page]', count: 0
        end
      end
    end

    test 'follow-up lists exclude removed coverage and older outcomes superseded by an open session' do
      eligible = new_session(:cancelled)
      removed = new_session(:no_show)
      assert removed.application.unassign_trainer!(actor: @admin)
      superseded = new_session(:cancelled)
      create(:training_session, :scheduled, application: superseded.application, trainer: @trainer)

      get needs_followup_trainers_training_sessions_path

      assert_response :success
      assert_equal [eligible.id], assigns(:training_sessions).pluck(:id)
      assert_not_includes assigns(:training_sessions), removed
      assert_not_includes assigns(:training_sessions), superseded
    end

    private

    def new_session(status, **attributes)
      application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
      create(:training_session, status, application: application, trainer: @trainer, **attributes)
    end

    def completion_params
      { completed_at: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'), product_trained_on_id: @product.id.to_s,
        duration_hours: '1.25', constituent_summary: 'Shared practice and next steps', summary_locale: 'es',
        internal_notes: 'Private report observations' }
    end

    def assert_input_value(selector, expected)
      assert_select selector do |nodes|
        assert_equal expected.to_s, nodes.sole['value'].to_s
      end
    end

    def assert_select_value(selector, expected)
      assert_select selector do |nodes|
        selected = nodes.sole.css('option[selected]').first || nodes.sole.css('option').first
        assert_equal expected.to_s, selected['value'].to_s
      end
    end

    def assert_completion_values(values)
      %i[completed_at duration_hours].each { |field| assert_input_value "#complete_#{field}", values[field] }
      %i[internal_notes constituent_summary].each { |field| assert_select "#complete_#{field}", text: values[field] }
      %i[product_trained_on_id summary_locale].each do |field|
        assert_select_value "#complete_#{field}", values[field].to_s
      end
    end
  end
end
