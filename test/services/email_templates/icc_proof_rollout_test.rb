# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class IccProofRolloutTest < ActiveSupport::TestCase
    setup do
      @actor = create(:admin)
      @templates = IccProofRollout::LEGACY_INTROS.flat_map do |action, locales|
        locales.map do |locale, intro|
          name = "application_notifications_proof_#{action}"
          template = EmailTemplate.find_or_initialize_by(name:, format: :text, locale:)
          template.update!(
            subject: 'Staff subject %<proof_type_formatted>s', description: 'Staff description',
            body: "Staff opening\n\n#{format(intro, proof: '%<proof_type_formatted>s')}\n\nStaff signature",
            variables: { 'required' => ['proof_type_formatted'] }, updated_by: @actor
          )
          template
        end
      end
    end

    test 'updates only eligibility variables and paragraphs, preserves the same rows, and reruns cleanly' do
      assert_equal 4, IccProofRollout.apply!(actor: @actor)
      @templates.each do |template|
        template.reload
        assert_equal 'Staff subject %<proof_type_formatted>s', template.subject
        assert_equal 'Staff description', template.description
        assert_match(/\AStaff opening\n.+\nStaff signature\z/m, template.body)
        assert_includes template.required_variables, 'request_explanation'
        assert_includes template.body, '%<request_explanation>s'
        assert Event.exists?(auditable: template, user: @actor, action: 'email_template_updated')
      end
      assert_equal 0, IccProofRollout.apply!(actor: @actor)
    end

    test 'a customized eligibility paragraph rolls back changes to the other templates' do
      customized = @templates.last
      customized.update!(body: 'Staff-customized instructions for %<proof_type_formatted>s.')
      previous = @templates.to_h { |template| [template.id, template.reload.attributes] }

      error = assert_raises(ArgumentError) { IccProofRollout.apply!(actor: @actor) }
      assert_match(/customized proof rejected paragraph in ES/, error.message)
      assert_equal(previous, @templates.to_h { |template| [template.id, template.reload.attributes] })
    end
  end
end
