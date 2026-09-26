# frozen_string_literal: true

require 'test_helper'

module Applications
  class AutosaveOrderingTest < ActiveSupport::TestCase
    setup do
      @user = create(:constituent, vision_disability: true, hearing_disability: false)
      @draft = create(:application, :draft, user: @user, household_size: 3)
      @context = SecureRandom.uuid
    end

    test 'a delayed older autosave cannot overwrite a newer departure save' do
      assert save_field('household_size', '7', 2)[:success]
      older = save_field('household_size', '4', 1)
      assert older[:success]
      assert_equal 7, @draft.reload.household_size
      assert_equal 'superseded', older[:outcome]
    end

    test 'a delayed autosave cannot overwrite a successful full form save' do
      result = ApplicationCreator.call(form(household_size: 7, autosave_revision: 2))
      assert result.success?, result.error_messages.inspect
      older = save_field('household_size', '4', 1)
      assert older[:success]
      assert_equal 7, @draft.reload.household_size
      assert_equal 'superseded', older[:outcome]
    end

    test 'fields arriving out of order are both saved and duplicates have no side effects' do
      assert save_field('annual_income', '40000', 2)[:success]
      assert save_field('household_size', '7', 1)[:success]
      before = @draft.reload.attributes
      duplicate = save_field('household_size', '4', 1)
      assert_equal 'superseded', duplicate[:outcome]
      assert_equal before, @draft.reload.attributes
      assert_equal 40_000, @draft.annual_income.to_i
    end

    test 'another page full save preserves the first page stale write protection' do
      assert save_field('household_size', '9', 5)[:success]
      first_page = @context
      @context = SecureRandom.uuid
      result = ApplicationCreator.call(form(household_size: 7, autosave_revision: 2))
      assert result.success?, result.error_messages.inspect
      @context = first_page
      assert_equal 'superseded', save_field('household_size', '4', 4)[:outcome]
      assert_equal 7, @draft.reload.household_size
      assert_equal 'saved', save_field('household_size', '8', 6)[:outcome]
      assert_equal 8, @draft.reload.household_size
    end

    test 'successful submission clears revision metadata and refuses delayed autosaves' do
      assert save_field('household_size', '9', 5)[:success]
      @context = SecureRandom.uuid
      assert save_field('household_size', '8', 1)[:success]
      submitted = form(household_size: 7, autosave_revision: 2)
      submitted.is_submission = true
      submitted.medical_provider_email = 'provider@example.org'
      assert submitted.valid?, submitted.errors.full_messages.inspect
      result = ApplicationCreator.call(submitted)
      assert result.success?, result.error_messages.inspect
      assert @draft.reload.status_in_progress?
      assert_empty @draft.autosave_revisions
      before = @draft.attributes
      assert_not save_field('household_size', '4', 1)[:success]
      assert_equal before, @draft.reload.attributes
    end

    test 'a rolled back submission retains the draft revision metadata' do
      assert save_field('household_size', '9', 5)[:success]
      before = @draft.reload.attributes
      submitted = form(household_size: 7, autosave_revision: 6)
      submitted.is_submission = true
      submitted.medical_provider_email = 'provider@example.org'
      assert submitted.valid?, submitted.errors.full_messages.inspect
      AuditEventService.stubs(:log).returns(true)
      AuditEventService.stubs(:log).with { |**args| args[:action] == 'application_status_changed' }
                                   .raises(StandardError, 'simulated submission audit failure')
      result = ApplicationCreator.call(submitted)
      assert result.failure?
      assert_includes result.error_messages, 'simulated submission audit failure'
      assert_equal before, @draft.reload.attributes
      assert_equal 'superseded', save_field('household_size', '4', 4)[:outcome]
    end

    test 'a refused full form save does not suppress pending autosaves' do
      invalid = form(household_size: 7, autosave_revision: 2)
      invalid.is_submission = true
      invalid.medical_provider_name = nil
      result = ApplicationCreator.call(invalid)
      assert result.failure?
      assert save_field('household_size', '4', 1)[:success]
      assert_equal 4, @draft.reload.household_size
    end

    test 'a first disability edit creates the draft that owns its ordering state' do
      @draft.destroy!
      @draft = nil
      assert_difference -> { Application.where(user: @user).count }, 1 do
        assert save_field('hearing_disability', true, 2)[:success]
      end
      assert save_field('hearing_disability', false, 1)[:success]
      assert @user.reload.hearing_disability
      assert_equal 1, Event.where(action: 'application_created', auditable: @user.applications.sole).count
    end

    test 'a first full form save accepts its page id before any autosave exists' do
      @draft.destroy!
      @draft = nil
      result = ApplicationCreator.call(form(household_size: 7, autosave_revision: 1))
      assert result.success?, result.error_messages.inspect
      assert_equal @user.id, result.application.user_id
      assert_equal 7, result.application.household_size
      assert_equal 1, @user.applications.count
    end

    test 'a full form clear remains blank when its earlier autosave arrives later' do
      previous = { medical_provider_name: 'Previous Provider', medical_provider_phone: '2025550123',
                   medical_provider_fax: '2025550124', medical_provider_email: 'provider@example.org' }
      @draft.update!(previous)
      submitted = form(household_size: 7, autosave_revision: 2)
      previous.each_key { |field| submitted.public_send("#{field}=", '') }
      result = ApplicationCreator.call(submitted)
      assert result.success?, result.error_messages.inspect
      previous.each do |field, value|
        assert @draft.reload.public_send(field).blank?, "#{field} must clear"
        assert_equal 'superseded', save_field(field, value, 1)[:outcome]
        assert @draft.reload.public_send(field).blank?, "#{field} must stay cleared"
      end
    end

    test 'omitted provider fields remain unchanged on a full save' do
      @draft.update!(medical_provider_fax: '2025550124', medical_provider_email: 'provider@example.org')
      result = ApplicationCreator.call(form(household_size: 7, autosave_revision: 2))
      assert result.success?, result.error_messages.inspect
      assert_equal '2025550124', @draft.reload.medical_provider_fax
      assert_equal 'provider@example.org', @draft.medical_provider_email
    end

    test 'a rolled back full form write does not consume the submission floor' do
      AuditEventService.stubs(:log).raises(StandardError, 'simulated required audit failure')
      result = ApplicationCreator.call(form(household_size: 7, autosave_revision: 2))
      assert result.failure?
      assert_equal 3, @draft.reload.household_size
      assert_empty @draft.autosave_revisions
      assert save_field('household_size', '4', 1)[:success]
      assert_equal 4, @draft.reload.household_size
    end

    private

    def save_field(field, value, revision)
      AutosaveService.new(current_user: @user, params: {
                            id: @draft&.id, field_name: "application[#{field}]", field_value: value,
                            autosave_context: @context, autosave_revision: revision
                          }).call
    end

    def form(**attributes)
      ApplicationForm.new(current_user: @user, application: @draft, params: {
        application: { annual_income: '50000', household_size: attributes[:household_size],
                       vision_disability: true, terms_accepted: true, information_verified: true,
                       medical_release_authorized: true,
                       medical_provider_attributes: { name: 'Test Provider', phone: '2025550123' } },
        autosave_context: @context, autosave_revision: attributes[:autosave_revision]
      }.with_indifferent_access)
    end
  end
end
