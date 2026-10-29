# frozen_string_literal: true

require 'test_helper'

# Every secure form issuer replaces links through SecureFormReplacement. The issuers' own tests
# cover their copy and delivery; these cover the shared cooldown, revocation, and token creation,
# including the digest-collision retry that no issuer test reaches.
class SecureFormReplacementTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @actor = create(:admin)
  end

  test 'a recent open link refuses the replacement, reports the remaining minutes, and stays open' do
    open, attributes = certification_subject
    existing = nil

    freeze_time do
      existing = create(:certification_upload_form, application: attributes[:application], sent_at: 10.minutes.ago)

      error = assert_raises(Applications::SecureRequestIssuance::CooldownActive) do
        SecureFormReplacement.replace!(open: open, actor: @actor, attributes: attributes)
      end

      remaining_minutes = (SecureFormPolicy.resend_cooldown_hours * 60) - 10
      assert_equal remaining_minutes, error.minutes
    end

    assert_predicate existing.reload, :status_sent?
    assert_equal [existing], open.to_a
  end

  test 'after the cooldown the open link is revoked as replaced and one new link is open' do
    open, attributes = certification_subject
    existing = create(:certification_upload_form,
                      application: attributes[:application],
                      sent_at: (SecureFormPolicy.resend_cooldown_hours + 1).hours.ago)

    issued = SecureFormReplacement.replace!(open: open, actor: @actor, attributes: attributes)
    form = issued.secure_request_form

    assert_predicate existing.reload, :status_revoked?
    revocation = Event.find_by!(action: 'cert_upload_request_revoked', auditable: attributes[:application])
    assert_equal 'replacement_request', revocation.metadata['reason']
    assert_equal [form], open.to_a
    assert_predicate form, :status_sent?
    assert_equal @actor, form.requested_by
    assert_equal SecureRequestForm.digest_public_token(issued.raw_token), form.public_token_digest
  end

  # The model's uniqueness validation catches a digest that already exists. RecordNotUnique arises
  # only when a concurrent insert wins the race, so these inserts skip validation to reach the index.
  %i[proof certification w9].each do |name|
    test "#{name} link retries once with a new token when a concurrent insert takes the digest" do
      open, attributes = subject_for(name)
      form_class = open.klass
      create(form_class.model_name.singular, raw_token: 'taken-token')
      form_class.stubs(:generate_public_token).returns('taken-token', 'fresh-token')

      issued = with_unvalidated_inserts(form_class) do
        inside_issuer_transaction { SecureFormReplacement.replace!(open: open, actor: @actor, attributes: attributes) }
      end

      assert_equal 'fresh-token', issued.raw_token
      assert_equal issued.secure_request_form, form_class.from_public_token('fresh-token')
    end
  end

  test 'a second digest collision raises and creates nothing' do
    open, attributes = subject_for(:w9)
    form_class = open.klass
    create(:vendor_secure_request_form, raw_token: 'taken-token')
    form_class.stubs(:generate_public_token).returns('taken-token')

    assert_no_difference 'VendorSecureRequestForm.count' do
      assert_raises(ActiveRecord::RecordNotUnique) do
        with_unvalidated_inserts(form_class, count: 2) do
          inside_issuer_transaction { SecureFormReplacement.replace!(open: open, actor: @actor, attributes: attributes) }
        end
      end
    end
  end

  private

  # Issuers call inside their own transaction, which test transactions would otherwise turn into a savepoint.
  def inside_issuer_transaction(&) = ApplicationRecord.transaction(&)

  def with_unvalidated_inserts(form_class, count: 1, &)
    original = form_class.method(:create!)
    calls = 0
    insert = lambda do |attributes|
      calls += 1
      if calls <= count
        form_class.new(attributes.merge(request_batch_id: SecureRandom.uuid)).save!(validate: false)
      else
        original.call(attributes)
      end
    end
    form_class.stub(:create!, insert, &)
  end

  def certification_subject
    application = create(:application)
    open = SecureRequestForm.open_certification_upload_for_application(application_id: application.id)
    [open, { application: application, kind: :certification_upload, recipient_role: :provider, recipient_channel: :email,
             recipient_email: 'provider@example.com', recipient_name: 'Dr. Provider' }]
  end

  def subject_for(name)
    case name
    when :proof
      application = create(:application)
      user = application.user
      open = SecureRequestForm.open_id_proof_for_recipient(application_id: application.id, recipient_id: user.id)
      [open, { application: application, kind: :id_proof_resubmission, recipient: user, recipient_email: user.email,
               recipient_channel: :email, recipient_role: :constituent, delivery_owner: user, delivery_source: 'constituent' }]
    when :certification
      certification_subject
    when :w9
      vendor = create(:vendor)
      [VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: vendor.id),
       { vendor: vendor, kind: :w9_upload, recipient_email: vendor.email }]
    end
  end
end
