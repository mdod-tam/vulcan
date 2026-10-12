# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class ContactContextTest < ActiveSupport::TestCase
    test 'uses the applications managing guardian rather than the first relationship' do
      first_guardian = create(:constituent, locale: 'en')
      managing_guardian = create(:constituent, locale: 'es', phone_type: 'text', preferred_means_of_communication: 'ASL')
      applicant = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                                       dependent_email: managing_guardian.email,
                                       phone: '000-123-4567', dependent_phone: managing_guardian.phone)
      create(:guardian_relationship, guardian_user: first_guardian, dependent_user: applicant)
      create(:guardian_relationship, guardian_user: managing_guardian, dependent_user: applicant)

      contact = context_for(applicant, guardian: managing_guardian)

      assert_equal managing_guardian, contact.guardian
      assert_equal managing_guardian.email, contact.email
      assert_equal managing_guardian, contact.email_owner
      assert_equal managing_guardian.phone, contact.phone
      assert_equal managing_guardian, contact.phone_owner
      assert_equal managing_guardian, contact.address_owner
      assert_equal 'text', contact.phone_type
      assert_equal 'es', contact.locale
      assert_equal 'ASL', contact.communication_modality
    end

    test 'keeps independently owned email and guardian phone with their respective languages' do
      guardian = create(:constituent, locale: 'es', phone_type: 'text', communication_preference: 'letter')
      applicant = create(:constituent, locale: 'en', communication_preference: 'email',
                                       phone: '000-123-4567', dependent_phone: guardian.phone)
      applicant.update!(dependent_email: applicant.email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)

      contact = context_for(applicant, guardian: guardian)

      assert_equal applicant.email, contact.email
      assert_equal applicant, contact.email_owner
      assert_equal guardian.phone, contact.phone
      assert_equal guardian, contact.phone_owner
      assert_equal 'en', contact.email_locale
      assert_equal 'es', contact.phone_locale
      assert_equal 'email', contact.communication_preference
    end

    test 'does not use an unrelated guardian when the application has no managing guardian' do
      guardian = create(:constituent)
      applicant = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                                       dependent_email: guardian.email,
                                       phone: '000-123-4567', dependent_phone: guardian.phone)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)

      contact = context_for(applicant)

      assert_nil contact.guardian
      assert_nil contact.email
      assert_nil contact.phone
      assert_equal applicant, contact.address_owner
    end

    test 'uses a complete applicant address when the guardian has no complete address' do
      guardian = create(:constituent, physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      applicant = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)

      assert_equal applicant, context_for(applicant, guardian: guardian).address_owner
    end

    test 'keeps dependent-owned contact after the application managing guardian is removed' do
      manager = create(:constituent)
      remaining_guardian = create(:constituent)
      applicant = create(:constituent)
      applicant.update!(dependent_email: applicant.email, dependent_phone: applicant.phone)
      create(:guardian_relationship, guardian_user: manager, dependent_user: applicant)
      create(:guardian_relationship, guardian_user: remaining_guardian, dependent_user: applicant)
      application = create(:application, user: applicant, managing_guardian: manager)
      evaluation = create(:evaluation, application: application, constituent: applicant)

      manager.destroy!
      contact = ContactContext.new(evaluation.reload)

      assert_nil application.reload.managing_guardian
      assert_nil contact.guardian
      assert_equal applicant.email, contact.email
      assert_equal applicant, contact.email_owner
      assert_equal applicant.phone, contact.phone
      assert_equal applicant, contact.phone_owner
      assert_not_equal remaining_guardian.email, contact.email
    end

    test 'preserves no-contact state and keeps alternate application contacts separate' do
      applicant = Current.instance.set(paper_context: true) do
        create(:constituent, email: nil, phone: nil, phone_type: 'letter', communication_preference: 'letter')
      end
      application = Application.new(user: applicant, alternate_contact_name: 'Appointment Helper',
                                    alternate_contact_email: 'helper@example.com', alternate_contact_phone: '410-555-0123',
                                    alternate_contact_relationship_type: 'Friend')
      contact = ContactContext.new(Evaluation.new(application: application, constituent: applicant))

      assert_nil contact.email
      assert_nil contact.phone
      assert_equal 'letter', contact.communication_preference
      assert_equal applicant, contact.address_owner
      assert_equal 'Appointment Helper', contact.alternate_contact_name
      assert_equal 'helper@example.com', contact.alternate_contact_email
      assert_equal '410-555-0123', contact.alternate_contact_phone
      assert_equal 'Friend', contact.alternate_contact_relationship_type
    end

    private

    def context_for(applicant, guardian: nil)
      application = Application.new(user: applicant, managing_guardian: guardian)
      ContactContext.new(Evaluation.new(application: application, constituent: applicant))
    end
  end
end
