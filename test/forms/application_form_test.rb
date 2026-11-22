# frozen_string_literal: true

require 'test_helper'

class ApplicationFormTest < ActiveSupport::TestCase
  setup do
    FeatureFlag.disable!(:vouchers_enabled)
    @user = create(:constituent, :with_disabilities)
  end

  test 'scalar checkbox and integer inputs are cast by the typed writers' do
    form = form_for(
      application: { maryland_resident: '0', self_certify_disability: '1', hearing_disability: '1', vision_disability: '',
                     terms_accepted: 'true', information_verified: '0', household_size: '3', user_id: '' }
    )

    assert_equal false, form.maryland_resident
    assert_equal true, form.self_certify_disability
    assert_equal true, form.hearing_disability
    assert_nil form.vision_disability
    assert_equal true, form.terms_accepted
    assert_equal false, form.information_verified
    assert_equal 3, form.household_size
    assert_nil form.user_id
  end

  test 'a blank household size stays blank instead of becoming zero' do
    assert_nil form_for(application: { household_size: '' }).household_size
  end

  test 'absent keys keep their defaults and arrays are dropped rather than read as checked' do
    form = form_for(application: { city: ['Baltimore'], hearing_disability: %w[0 1], maryland_resident: %w[0 1] })

    assert_nil form.city
    assert_equal false, form.hearing_disability
    assert_equal true, form.maryland_resident
    assert_equal false, form.terms_accepted
  end

  test 'currency formatting is removed from annual income' do
    assert_equal '50000.50', form_for(application: { annual_income: '$50,000.50' }).annual_income
  end

  test 'final income submission accepts zero and exact configured limits for households eight through ten' do
    [8, 9, 10].each do |size|
      threshold = IncomeThresholdCalculationService.call(size).data.fetch(:threshold)
      assert submission_form(income: threshold.to_s('F'), size: size).valid?
      excessive = submission_form(income: (threshold + BigDecimal('0.01')).to_s('F'), size: size)
      assert_not excessive.valid?
      assert excessive.errors.of_kind?(:annual_income, :income_above_limit)
    end
    assert submission_form(income: '0').valid?
  end

  test 'final income submission refuses malformed amounts and household values without changing their meaning' do
    ['-1', 'not 12 dollars', 'NaN', 'Infinity', '1,2', '10.005'].each do |value|
      form = submission_form(income: value)
      assert_equal value, form.annual_income
      assert_not form.valid?, value
      assert form.errors.of_kind?(:annual_income, :invalid_amount), value
    end
    ['2.5', '2 people', '0', '-1', ''].each do |value|
      form = submission_form(income: '0', size: value)
      assert_not form.valid?, value
      assert form.errors.of_kind?(:household_size, :positive_integer), value
    end
  end

  test 'income errors use the form locale and explain a missing policy without submitting' do
    form = submission_form(income: '999999')
    form.locale = 'es'
    assert_not form.valid?
    assert_includes form.errors[:annual_income], I18n.t('activemodel.errors.models.application_form.attributes.annual_income.income_above_limit', locale: :es)

    Policy.find_by!(key: 'fpl_2_person').destroy!
    form = submission_form(income: '0')
    form.locale = 'es'
    assert_not form.valid?
    assert_includes form.errors[:base], I18n.t('activemodel.errors.models.application_form.attributes.base.income_check_unavailable', locale: :es)
  end

  test 'drafts remain resumable and persisted income requirements survive a global flag change' do
    draft = form_for(application: { annual_income: '999999', household_size: '2' }, save_draft: 'Save')
    assert draft.valid?
    persisted = create(:application, :draft, user: @user, income_proof_required: true)
    FeatureFlag.enable!(:vouchers_enabled)
    form = submission_form(income: '999999')
    form.application = persisted
    assert_not form.valid?
    assert form.errors.of_kind?(:annual_income, :income_above_limit)

    persisted.income_proof_required = false
    assert form.valid?, form.errors.full_messages.to_sentence
  end

  test 'the top-level guardian address checkbox takes precedence over the nested one' do
    assert_equal false, form_for(application: { use_guardian_address: '1' }, use_guardian_address: '0').use_guardian_address
    assert_equal true, form_for(application: { use_guardian_address: '1' }).use_guardian_address
    assert_equal true, form_for(application: { city: 'x' }, use_guardian_address: '1').use_guardian_address
    assert_equal false, form_for(application: { city: 'x' }).use_guardian_address
  end

  test 'nested provider fields and the submitted locale are extracted' do
    form = form_for(constituent: { locale: 'es' },
                    application: { certifying_professional_attributes: { name: 'Dr. A', phone: '2025550123', email: 'a@example.com' } })

    assert_equal ['Dr. A', '2025550123', 'a@example.com'],
                 [form.certifying_professional_name, form.certifying_professional_phone, form.certifying_professional_email]
    assert_equal 'es', form.locale
  end

  test 'a submitted dependent id must belong to the acting guardian' do
    dependent = create(:constituent)
    GuardianRelationship.create!(guardian_user: @user, dependent_user: dependent, relationship_type: 'parent')

    assert_equal dependent, form_for(application: { user_id: dependent.id.to_s }).applicant_user

    outsider = form_for(application: { user_id: create(:constituent).id.to_s })
    assert_nil outsider.applicant_user
    assert_includes outsider.errors.where(:user_id).map(&:message), 'is not a valid dependent.'
  end

  test 'form errors import into an application with their symbolic types, form translations, and application labels' do
    form = form_for(application: { city: 'Baltimore' }, submit_application: 'Submit Application')
    assert_not form.valid?
    application = Application.new
    application.errors.add(:base, 'Existing problem')

    application.errors.merge!(form.errors)

    assert_includes application.errors.full_messages, 'Existing problem'
    assert application.errors.added?(:base, :certifying_professional_required)
    assert application.errors.added?(:annual_income, :blank)
    assert_includes application.errors.full_messages, "Annual income can't be blank"
    %i[en es].each do |locale|
      expected = I18n.t('activemodel.errors.models.application_form.attributes.base.certifying_professional_required', locale: locale)
      assert_includes I18n.with_locale(locale) { application.errors.full_messages }, expected
    end
  end

  private

  def submission_form(income:, size: 2)
    form_for(application: { annual_income: income, household_size: size, hearing_disability: true,
                            certifying_professional_attributes: { name: 'Dr. A', phone: '2025550123', email: 'a@example.com' } },
             submit_application: 'Submit Application')
  end

  def form_for(application:, **top_level)
    ApplicationForm.new(current_user: @user, params: ActionController::Parameters.new(application: application, **top_level))
  end
end
