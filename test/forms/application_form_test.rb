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

  test 'the top-level guardian address checkbox takes precedence over the nested one' do
    assert_equal false, form_for(application: { use_guardian_address: '1' }, use_guardian_address: '0').use_guardian_address
    assert_equal true, form_for(application: { use_guardian_address: '1' }).use_guardian_address
    assert_equal true, form_for(application: { city: 'x' }, use_guardian_address: '1').use_guardian_address
    assert_equal false, form_for(application: { city: 'x' }).use_guardian_address
  end

  test 'nested provider fields and the submitted locale are extracted' do
    form = form_for(constituent: { locale: 'es' },
                    application: { medical_provider_attributes: { name: 'Dr. A', phone: '2025550123', email: 'a@example.com' } })

    assert_equal ['Dr. A', '2025550123', 'a@example.com'],
                 [form.medical_provider_name, form.medical_provider_phone, form.medical_provider_email]
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
    assert application.errors.added?(:base, :medical_provider_required)
    assert application.errors.added?(:annual_income, :blank)
    assert_includes application.errors.full_messages, "Annual income can't be blank"
    %i[en es].each do |locale|
      expected = I18n.t('activemodel.errors.models.application_form.attributes.base.medical_provider_required', locale: locale)
      assert_includes I18n.with_locale(locale) { application.errors.full_messages }, expected
    end
  end

  private

  def form_for(application:, **top_level)
    ApplicationForm.new(current_user: @user, params: ActionController::Parameters.new(application: application, **top_level))
  end
end
