# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationCertificationFormsControllerTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    include AuthenticationTestHelper
    include ConcurrencyTestHelper

    setup do
      Current.reset
      @existing_system_actor = User.system_user
      ensure_system_audit_actor!
      @admin = create(:admin)
      @original_controls = FeatureFlag.where(name: EmailDelivery::CONTROL_NAMES).to_h do |control|
        [control.name, control.slice(:enabled, :delivery_generation, :updated_at)]
      end
      EmailDelivery::CONTROL_NAMES.each do |name|
        FeatureFlag.find_or_create_by!(name: name) { |flag| flag.enabled = true }
        EmailDelivery::ControlWriter.set(name: name, enabled: true, actor: @admin, operation_id: SecureRandom.uuid)
      end
      @constituent = create(:constituent)
      @application = create(
        :application, :in_progress,
        user: @constituent,
        certifying_professional_email: 'doctor@example.com',
        certifying_professional_name: 'Dr. Jane Smith'
      )
      sign_in_for_integration_test(@admin)
    end

    teardown do
      # Restore fixture state; toggling back on preserves a generation raised by the test.
      EmailDelivery::CONTROL_NAMES.each do |name|
        if @original_controls.key?(name)
          control = FeatureFlag.find_by!(name: name)
          control.update_columns(@original_controls.fetch(name))
          assert_equal @original_controls.fetch(name), control.reload.slice(:enabled, :delivery_generation, :updated_at)
        else
          FeatureFlag.find_by(name: name)&.destroy!
          assert_not FeatureFlag.exists?(name: name)
        end
      end
      cleanup_duplicate_review_test_data!(@constituent, @admin)
      cleanup_duplicate_review_test_data!(User.system_user) unless @existing_system_actor
      Current.reset
    end

    test 'a provider timeout tells staff to verify handoff before sending again' do
      Docuseal.expects(:create_submission).once.raises(Net::ReadTimeout)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      assert_match 'DocuSeal may have accepted', flash[:alert]
      assert_match 'before sending another', flash[:alert]
      assert_no_match 'Failed to send signing request', flash[:alert]
      assert_nil flash[:notice]
      assert_nil @application.reload.document_signing_submission_id
      assert Event.exists?(action: 'document_signing_request_unconfirmed', auditable: @application)
      follow_redirect!
      assert_select '[data-testid="flash-alert"]', text: /DocuSeal may have accepted/
    end

    test 'a committed request with a completion failure shows recovery guidance instead of a success notice' do
      Docuseal.expects(:create_submission).once.returns({ 'id' => 'committed-submission', 'submitters' => [{ 'id' => 'signer' }] })
      application_id = @application.id
      callback = -> { raise 'completion failed' if id == application_id }
      Application.set_callback(:commit, :after, callback)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      assert_match 'accepted the signing request and it was saved', flash[:alert]
      assert_match 'before sending another', flash[:alert]
      assert_nil flash[:notice]
      assert_equal 'committed-submission', @application.reload.document_signing_submission_id
      assert Event.exists?(action: 'document_signing_follow_up_failed', auditable: @application)
      follow_redirect!
      assert_select '[data-testid="flash-alert"]', text: /accepted the signing request and it was saved/
    ensure
      Application.skip_callback(:commit, :after, callback) if callback
    end
  end
end
