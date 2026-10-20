# frozen_string_literal: true

require 'test_helper'

module Admin
  class TrainingCompletionTemplatesTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      load_seeded_email_templates('training_session_notifications_training_completed')
      @template = EmailTemplate.find_by!(name: 'training_session_notifications_training_completed', format: :text, locale: 'en')
    end

    test 'editor and draft preview reject private or unknown completion placeholders for both syntaxes' do
      { legacy_percent: '%<internal_notes>s', liquid: '{{ cancellation_reason }}' }.each do |syntax, placeholder|
        body = public_body(syntax) + "\n#{placeholder}"
        patch admin_email_template_path(@template), params: {
          locale: 'en', email_template: { subject: 'Training report', body: body, description: 'Confirmation', syntax: syntax,
                                          variables: { required: ['internal_notes'] } }
        }
        assert_response :unprocessable_content
        assert_includes response.body, 'not available for this template'
        assert_not_includes @template.reload.body, placeholder
        assert_not_includes @template.allowed_variables, 'internal_notes'

        patch preview_admin_email_template_path(@template), headers: { 'Turbo-Frame' => 'template-preview-en' }, params: {
          locale: 'en', email_template: { subject: 'Training report', body: body, description: 'Confirmation', syntax: syntax }
        }
        assert_response :unprocessable_content
        assert_includes response.body, 'not available for this template'
        assert_not_includes response.body, 'PRIVATE TRAINING'
      end
    end

    test 'test send refuses an unsafe persisted completion template in either syntax' do
      { legacy_percent: '%<internal_notes>s', liquid: '{{ constituent_summary }}' }.each do |syntax, placeholder|
        # Simulate an invalid preexisting database record; runtime must still enforce the allowlist.
        @template.update_columns(syntax: EmailTemplate.syntaxes.fetch(syntax.to_s), subject: 'Training report', body: placeholder)
        assert_no_enqueued_jobs(only: EmailDelivery::MailDeliveryJob) do
          post send_test_admin_email_template_path(@template), params: {
            admin_test_email_form: { email: @admin.email, template_id: @template.id }
          }
        end
        assert_response :unprocessable_content
        assert_match(/not available|placeholder/, flash[:alert])
      end
    end

    private

    def public_body(syntax)
      @template.required_variables.map do |name|
        syntax == :liquid ? "{{ #{name} }}" : "%<#{name}>s"
      end.join("\n")
    end
  end
end
