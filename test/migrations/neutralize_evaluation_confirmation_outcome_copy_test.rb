# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261011120100_neutralize_evaluation_confirmation_outcome_copy'

class NeutralizeEvaluationConfirmationOutcomeCopyTest < ActiveSupport::TestCase
  setup do
    %w[evaluator_mailer_evaluation_submission_confirmation evaluator_mailer_evaluation_submission_confirmation_es].each do |name|
      load Rails.root.join("db/seeds/email_templates/#{name}.rb")
    end
    @migration = NeutralizeEvaluationConfirmationOutcomeCopy.new
  end

  test 'up changes only exact stock text bodies and preserves the editable template contract' do
    templates = %w[en es].map do |locale|
      template = confirmation_template(locale)
      template.update_columns(body: NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch(locale),
                              subject: "Staff subject #{locale}", version: 4)
      template
    end

    @migration.up

    templates.each do |template|
      template.reload
      assert_equal NeutralizeEvaluationConfirmationOutcomeCopy::NEW_BODIES.fetch(template.locale), template.body
      assert_equal "Staff subject #{template.locale}", template.subject
      assert_equal 5, template.version
      assert_includes template.required_variables, 'recommended_products_text_list'
      assert_equal NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch(template.locale), template.previous_body
    end
  end

  test 'admin edited bodies and other template formats are not changed' do
    edited = confirmation_template('en')
    edited.update_columns(body: "Staff introduction\n%<recommended_products_text_list>s", version: 8)
    other_format = NeutralizeEvaluationConfirmationOutcomeCopy::Template.find_or_initialize_by(
      name: NeutralizeEvaluationConfirmationOutcomeCopy::TEMPLATE_NAME, format: 0, locale: 'en'
    )
    other_format.update!(
      body: NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch('en'), subject: 'HTML confirmation',
      description: 'Unrelated format', version: 3, created_at: Time.current, updated_at: Time.current
    )
    original_attributes = [edited, other_format].map(&:attributes)

    @migration.up

    current_attributes = [edited, other_format].map { |template| template.reload.attributes }
    assert_equal original_attributes, current_attributes
  end

  test 'down restores untouched replacement bodies and preserves edits made after migration' do
    %w[en es].each do |locale|
      confirmation_template(locale).update_columns(body: NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch(locale))
    end
    @migration.up
    spanish = confirmation_template('es')
    spanish.update_columns(body: "Updated staff wording\n%<recommended_products_text_list>s")

    @migration.down

    assert_equal NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch('en'), confirmation_template('en').body
    assert_equal "Updated staff wording\n%<recommended_products_text_list>s", spanish.reload.body
  end

  test 'current stock seeds match the neutral replacement bodies' do
    %w[en es].each do |locale|
      assert_equal NeutralizeEvaluationConfirmationOutcomeCopy::NEW_BODIES.fetch(locale), confirmation_template(locale).body
    end
  end

  private

  def confirmation_template(locale)
    EmailTemplate.find_by!(name: NeutralizeEvaluationConfirmationOutcomeCopy::TEMPLATE_NAME, format: :text, locale: locale)
  end
end
