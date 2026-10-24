# frozen_string_literal: true

require 'test_helper'

class DocumentScanAcceptanceTest < ActiveSupport::TestCase
  %w[pending blocked clean].each do |verdict|
    test "proof replacement requires #{verdict} clearance without losing the original" do
      admin = create(:admin)
      application = create(:application, :with_income_proof)
      original = application.income_proof.blob
      replacement = scanned_fixture(admin, :proof, verdict)
      result = ProofAttachmentService.attach_proof(application: application, proof_type: :income,
                                                   blob_or_file: replacement.signed_id, admin: admin, submission_method: :web)
      assert_equal verdict == 'clean', result[:success]
      assert_equal verdict == 'clean' ? replacement.id : original.id, application.reload.income_proof.blob.id
      assert original.service.exist?(original.key)
    end

    test "portal creation accepts only #{verdict} cleared receipts" do
      user = create(:constituent)
      application = create(:application, :draft, user: user)
      blob = scanned_fixture(user, :proof, verdict)
      form = ApplicationForm.new(current_user: user, application: application, income_proof: blob.signed_id, hearing_disability: true,
                                 physical_address_1: user.physical_address_1, city: user.city, state: user.state, zip_code: user.zip_code)
      result = Applications::ApplicationCreator.call(form)
      assert_equal verdict == 'clean', result.success?, result.error_messages.inspect
      assert_equal verdict == 'clean', application.reload.income_proof.attached?
    end

    test "public guidance publication requires #{verdict} clearance" do
      admin = create(:admin)
      resource = create(:product).product_resources.new
      blob = scanned_fixture(admin, :product_resource, verdict)
      result = ProductResources::Writer.new(resource: resource, actor: admin).save(
        attributes: { title: 'Guide', locale: 'en' }, source: 'pdf', document: blob.signed_id
      )
      assert_equal verdict == 'clean', result
      assert_equal verdict == 'clean', resource.persisted?
    end

    test "W9 replacement requires #{verdict} clearance" do
      vendor = create(:vendor, :with_w9)
      original = vendor.w9_form.blob
      blob = scanned_fixture(vendor, :w9, verdict)
      if verdict == 'clean'
        Vendors::ReplaceW9.call(vendor: vendor, file: blob.signed_id)
        assert_equal blob.id, vendor.reload.w9_form.blob.id
      else
        assert_raises(UploadedDocument::Refused) { Vendors::ReplaceW9.call(vendor: vendor, file: blob.signed_id) }
        assert_equal original.id, vendor.reload.w9_form.blob.id
      end
    end
  end

  private

  def scanned_fixture(user, purpose, verdict)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4\n#{'x' * 2000}"), filename: 'document.pdf', content_type: 'application/pdf')
    mark_document_clean!(blob, user: user, purpose: purpose)
    DocumentScan.find_by!(blob: blob).update!(status: verdict)
    blob
  end
end
