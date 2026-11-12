# frozen_string_literal: true

module TrainingSystemTestSetup
  extend ActiveSupport::Concern

  included do
    setup do
      @trainer = create(:trainer)
      @constituent = create(:constituent, first_name: 'Morgan', last_name: 'Learner')
      @application = create(:application, :approved, :with_all_proofs, user: @constituent, assigned_trainer: @trainer, application_date: Date.current)
      @session = create(:training_session, application: @application, trainer: @trainer)
      @product = create(:product, name: 'Practice captions device')
      @other_product = create(:product, name: 'Alternative practice device')
      create(:product_resource, product: @product, title: 'Captions practice guide')
      create(:product_resource, product: @product, title: 'Guía para practicar subtítulos', locale: 'es')
      system_test_sign_in(@trainer, bypass_mfa_enrollment: true)
    end

    teardown do
      Timeout.timeout(10) { Capybara.current_session.server&.wait_for_pending_requests }
    end
  end

  private

  def switch_user(user, bypass_mfa_enrollment: false)
    page.current_window.resize_to(1200, 900)
    system_test_switch_user(user, bypass_mfa_enrollment:)
  end

  def assert_action_error(action, heading: 'Please correct the following errors')
    assert_single_action_error("#{action.dasherize}-errors", heading:)
  end

  def observe_native_submission
    page.execute_script <<~JS
      window.trainingSubmissions = [];
      document.addEventListener('turbo:submit-start', event => {
        const submitter = event.detail.formSubmission.submitter;
        window.trainingSubmissions.push({ disabled: submitter.disabled, label: submitter.value, id: submitter.id });
      }, { once: true });
    JS
  end

  def assert_native_submission(label, submitter_id: nil)
    submissions = page.evaluate_script('window.trainingSubmissions')
    assert_equal([{ 'disabled' => true, 'label' => label }], submissions.map { |submission| submission.slice('disabled', 'label') })
    assert_equal([submitter_id], submissions.pluck('id')) if submitter_id
  end
end
