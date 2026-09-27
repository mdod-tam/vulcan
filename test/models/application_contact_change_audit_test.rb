# frozen_string_literal: true

require 'test_helper'

class ApplicationContactChangeAuditTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @application = create(:application, status: :awaiting_proof)
    Current.user = @admin
  end

  teardown do
    Current.reset
  end

  test 'creating an application records no provider change event' do
    assert_equal 0, Event.where(action: 'medical_provider_info_updated', auditable: @application).count
  end

  test 'a staff edit records old and new provider values without a review flag' do
    old_email = @application.medical_provider_email

    @application.update!(medical_provider_email: 'updated-provider@example.test')

    event = Event.find_by!(action: 'medical_provider_info_updated', auditable: @application)
    assert_equal @admin, event.user
    assert_equal({ 'old' => old_email, 'new' => 'updated-provider@example.test' },
                 event.metadata['changes']['medical_provider_email'])
    assert_equal ['medical_provider_email'], event.metadata['changes'].keys
    assert_nil event.metadata['review_required']
  end

  test 'provider values typed into a draft are not recorded' do
    draft = create(:application, :draft)

    draft.update!(medical_provider_email: 'draft-provider@example.test')

    assert_equal 0, Event.where(action: 'medical_provider_info_updated', auditable: draft).count
  end

  test 'two different provider edits in quick succession are both recorded' do
    @application.update!(medical_provider_phone: '410-555-0111')
    @application.update!(medical_provider_phone: '410-555-0122')

    assert_equal 2, Event.where(action: 'medical_provider_info_updated', auditable: @application).count
  end

  test 'alternate contact edits still record old and new values' do
    @application.update!(alternate_contact_name: 'New Alternate')

    event = Event.find_by!(action: 'alternate_contact_updated', auditable: @application)
    assert_equal 'New Alternate', event.metadata['changes']['alternate_contact_name']['new']
  end

  test 'provider info requests stay visible while a link is active after the info is complete' do
    assert_not @application.missing_required_provider_info?
    assert_not @application.provider_info_requests_visible?

    create(:secure_request_form, application: @application, recipient: @application.user)
    assert_predicate @application, :provider_info_requests_visible?

    @application.update_columns(medical_provider_email: '')
    @application.secure_request_forms.update_all(status: SecureRequestForm.statuses[:revoked], revoked_at: Time.current)
    assert_predicate @application.reload, :provider_info_requests_visible?
  end
end
