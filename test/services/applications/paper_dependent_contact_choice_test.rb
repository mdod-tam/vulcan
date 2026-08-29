# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperDependentContactChoiceTest < ActiveSupport::TestCase
    test 'refuses a blank own email choice' do
      result = contact_choice(email_strategy: 'dependent', dependent_email: '').call

      assert_not result.valid?
      assert_equal :dependent_email, result.field
      assert_equal :missing_dependent_email, result.reason
      assert_equal "Enter the dependent's email or choose the guardian's email address.", result.message
    end

    test 'refuses a blank own phone choice independently of email' do
      result = contact_choice(
        email_strategy: 'dependent',
        phone_strategy: 'dependent',
        dependent_email: 'dependent@example.com',
        dependent_phone: ''
      ).call

      assert_not result.valid?
      assert_equal :dependent_phone, result.field
      assert_equal :missing_dependent_phone, result.reason
      assert_equal "Enter the dependent's phone or choose the guardian's phone number.", result.message
    end

    test 'accepts blank own values when guardian contact is selected' do
      result = contact_choice(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        dependent_email: '',
        dependent_phone: ''
      ).call

      assert result.valid?
    end

    test 'accepts populated own contact values' do
      result = contact_choice(
        email_strategy: 'dependent',
        phone_strategy: 'dependent',
        dependent_email: 'dependent@example.com',
        dependent_phone: '410-555-0199'
      ).call

      assert result.valid?
    end

    test 'resolves an omitted existing-dependent field from real on-file contact' do
      guardian = create(:constituent, email: 'guardian-choice@example.com')
      own_email = 'dependent-choice@example.com'
      dependent = create(
        :constituent,
        email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
        dependent_email: own_email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)

      result = PaperDependentContactChoice.new(
        applicant_data: {},
        strategy_params: { email_strategy: 'dependent', phone_strategy: 'guardian' },
        existing_dependent: dependent,
        guardian: guardian
      ).call

      assert result.valid?
      assert_equal own_email, result.resolved_applicant_data[:dependent_email]
    end

    test 'does not hide a submitted blank behind existing contact' do
      guardian = create(:constituent, email: 'guardian-explicit-blank@example.com')
      dependent = create(:constituent, dependent_email: 'dependent-on-file@example.com')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)

      result = PaperDependentContactChoice.new(
        applicant_data: { dependent_email: '' },
        strategy_params: { email_strategy: 'dependent', phone_strategy: 'guardian' },
        existing_dependent: dependent,
        guardian: guardian
      ).call

      assert_not result.valid?
      assert_equal :missing_dependent_email, result.reason
    end

    test 'refuses an omitted own-contact choice when the existing record has no own contact' do
      guardian = create(:constituent, email: 'guardian-routed@example.com')
      dependent = create(
        :constituent,
        email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)

      result = PaperDependentContactChoice.new(
        applicant_data: {},
        strategy_params: { email_strategy: 'dependent', phone_strategy: 'guardian' },
        existing_dependent: dependent,
        guardian: guardian
      ).call

      assert_not result.valid?
      assert_equal :missing_dependent_email, result.reason
    end

    private

    def contact_choice(email_strategy:, phone_strategy: 'guardian', dependent_email: nil, dependent_phone: nil)
      PaperDependentContactChoice.new(
        applicant_data: { dependent_email: dependent_email, dependent_phone: dependent_phone },
        strategy_params: { email_strategy: email_strategy, phone_strategy: phone_strategy }
      )
    end
  end
end
