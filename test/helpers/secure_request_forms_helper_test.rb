# frozen_string_literal: true

require 'test_helper'

class SecureRequestFormsHelperTest < ActionView::TestCase
  include SecureRequestFormsHelper

  test 'issued postal destination does not change when the address changes' do
    owner = create(:constituent)
    form = create(:secure_request_form, recipient: owner, delivery_owner: owner,
                                        recipient_channel: :letter)

    assert_equal 'Postal mail', secure_request_masked_contact(form)
    owner.update!(physical_address_1: '98 Updated Road')
    assert_equal 'Postal mail', secure_request_masked_contact(form.reload)
  end

  test 'summary copy uses date-only sent and expiration details' do
    summary = {
      summary_status: :active,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: Time.zone.local(2026, 5, 24, 15, 43)
    }

    assert_equal 'Sent May 22', secure_request_summary_sent_text(summary)
    assert_equal 'Expires May 24', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Expires May 24.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy shows expired instead of an expired timestamp' do
    summary = {
      summary_status: :expired,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: Time.zone.local(2026, 5, 24, 15, 43)
    }

    assert_equal 'Expired', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Expired.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy shows revoked for recently revoked requests' do
    summary = {
      summary_status: :revoked,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: nil
    }

    assert_equal 'Revoked', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Revoked.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy omits expiration text when status is not visible' do
    summary = {
      summary_status: nil,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: nil
    }

    assert_nil secure_request_summary_expiration_text(summary)
  end

  test 'proof resubmission detail leads with rejection context when proof is rejected' do
    application = create(:application, id_proof_status: :rejected)
    admin = create(:admin)
    create(:proof_review,
           :rejected,
           application: application,
           admin: admin,
           proof_type: :id,
           rejection_reason: 'Too blurry')
    notification = create(
      :notification,
      recipient: application.user,
      actor: admin,
      notifiable: application,
      action: 'proof_resubmission_requested',
      metadata: {
        'proof_type' => 'id',
        'proof_request_display_mode' => 'rejected',
        'rejection_reason' => 'Too blurry',
        'recipient_channel' => 'email'
      }
    )

    detail = send(:secure_proof_resubmission_notification_detail, notification, notification.metadata)

    assert_includes detail, 'ID proof rejected - Too blurry; secure upload link sent to'
    assert_includes detail, 'via Email'
  end

  test 'proof resubmission detail leads with request context when proof is not rejected' do
    application = create(:application, id_proof_status: :not_reviewed)
    admin = create(:admin)
    create(:proof_review,
           :rejected,
           application: application,
           admin: admin,
           proof_type: :id,
           rejection_reason: 'Old blurry document')
    application.update!(id_proof_status: :not_reviewed)
    notification = create(
      :notification,
      recipient: application.user,
      actor: admin,
      notifiable: application,
      action: 'proof_resubmission_requested',
      metadata: {
        'proof_type' => 'id',
        'proof_request_display_mode' => 'requested',
        'recipient_channel' => 'email'
      }
    )

    detail = send(:secure_proof_resubmission_notification_detail, notification, notification.metadata)

    assert_includes detail, 'ID proof requested; secure upload link sent to'
    assert_not_includes detail, 'Old blurry document'
  end

  test 'issued letter contact omits mutable delivery owner address' do
    guardian = create(:constituent, physical_address_1: '9 Guardian Way', city: 'Baltimore',
                                    state: 'MD', zip_code: '21201')
    dependent = create(:constituent)
    form = create(:secure_request_form, recipient: dependent, recipient_channel: :letter,
                                        recipient_email: nil, recipient_phone: nil,
                                        delivery_owner: guardian, delivery_source: 'managing_guardian')

    assert_equal 'Postal mail', secure_request_masked_contact(form)
  end

  test 'legacy issued letter contact does not guess its address owner' do
    recipient = create(:constituent, physical_address_1: '1 Home St', city: 'Bowie',
                                     state: 'MD', zip_code: '20715')
    form = create(:secure_request_form, recipient: recipient, recipient_channel: :letter,
                                        recipient_email: nil, recipient_phone: nil)

    assert_equal 'Postal mail', secure_request_masked_contact(form)

    recipient.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
    assert_equal 'Postal mail', secure_request_masked_contact(form.reload)
  end

  test 'delivery owner label qualifies guardians and leaves other sources unqualified' do
    owner = create(:constituent, first_name: 'Jane', last_name: 'Smith')

    assert_equal "Jane Smith (Guardian) (ID: #{owner.id})", secure_request_delivery_owner_label(owner)
    assert_equal "Jane Smith (Guardian) (ID: #{owner.id})",
                 secure_request_delivery_owner_label(owner, delivery_source: 'managing_guardian')
    assert_equal "Jane Smith (ID: #{owner.id})", secure_request_delivery_owner_label(owner, delivery_source: 'constituent')
  end

  test 'candidate destination text masks the resolved digital destination' do
    recipient = create(:constituent, email: "jane.doe.#{SecureRandom.hex(4)}@example.com")
    candidate = Applications::SecureRequestRecipientResolver::Candidate.new(
      recipient: recipient,
      available_channels: %i[email],
      channel: :email,
      email: recipient.email,
      email_owner: recipient,
      contact_owner: recipient
    )
    candidate.define_singleton_method(:deliverable_channels) { %i[email] }

    assert_equal 'Delivers to j***@example.com', secure_request_candidate_destination_text(candidate)
  end

  test 'candidate destination text names a differing delivery owner' do
    guardian = create(:constituent, first_name: 'Jane', last_name: 'Smith',
                                    email: "jane.smith.#{SecureRandom.hex(4)}@example.com")
    dependent = create(:constituent)
    candidate = Applications::SecureRequestRecipientResolver::Candidate.new(
      recipient: dependent,
      available_channels: %i[email],
      channel: :email,
      email: guardian.email,
      email_owner: guardian,
      contact_owner: guardian
    )
    candidate.define_singleton_method(:deliverable_channels) { %i[email] }

    assert_equal "Delivers to Jane Smith (Guardian) (ID: #{guardian.id}) — j***@example.com",
                 secure_request_candidate_destination_text(candidate)
  end

  test 'candidate destination text renders the letter mailing destination' do
    owner = create(:constituent, physical_address_1: '9 Guardian Way', city: 'Baltimore',
                                 state: 'MD', zip_code: '21201')
    candidate = Applications::SecureRequestRecipientResolver::Candidate.new(
      recipient: owner,
      available_channels: %i[letter],
      channel: :letter,
      address_owner: owner
    )
    candidate.define_singleton_method(:deliverable_channels) { %i[letter] }

    assert_equal 'Delivers to 9 Guardian Way, Baltimore, MD 21201',
                 secure_request_candidate_destination_text(candidate)
  end

  test 'candidate destination text is blank without a resolvable channel' do
    recipient = create(:constituent)
    candidate = Applications::SecureRequestRecipientResolver::Candidate.new(
      recipient: recipient,
      available_channels: [],
      channel: nil
    )
    candidate.define_singleton_method(:deliverable_channels) { [] }

    assert_nil secure_request_candidate_destination_text(candidate)
  end
end
