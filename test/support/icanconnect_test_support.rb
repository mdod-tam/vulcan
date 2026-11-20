# frozen_string_literal: true

module IcanconnectTestSupport
  def start_icanconnect!(on: Date.new(2000, 1, 1))
    Icanconnect::Setting.find_or_initialize_by(id: Icanconnect::Setting::ID).tap { |setting| setting.update!(starts_on: on) }
  end

  def icc_blob(slot: 'financial_document', purpose: :financial_evidence)
    blob = ActiveStorage::Blob.create_and_upload!(io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
                                                  filename: 'evidence.pdf', content_type: 'application/pdf')
    DocumentScanFixtures.clear!(blob, user: @admin, purpose: purpose, slot: slot, fixture: 'disability_certification_valid.pdf')
    blob
  end

  def approved_deafblind_application(**attributes)
    attributes[:user] ||= create(:constituent, hearing_disability: true, vision_disability: true)
    application = create(:application, :draft, :with_all_proofs, program_disability_groups: ['deafblind'], **attributes)
    application.update!(terms_accepted: true, information_verified: true, disability_information_release_authorized: true,
                        income_proof_required: true, fulfillment_type: :equipment,
                        income_proof_status: :not_reviewed, residency_proof_status: :not_reviewed, id_proof_status: :not_reviewed,
                        disability_certification_status: :approved)
    application.submit!(actor: @admin)
    %w[income residency id].each do |type|
      Applications::ProofReviewer.new(application, @admin).review(proof_type: type, status: :approved,
                                                                  decision_key: SecureRandom.uuid,
                                                                  reviewed_blob_id: application.document_attachment_for(type).blob.id)
    end
    application
  end

  def icc_order_with_unit(application: approved_deafblind_application, cost: 150)
    po = create(:purchase_order, funding_source: 'icanconnect', sent_at: Date.current,
                                 vendor_name: 'Test supplier', vendor_invoice_number: 'ICC-INVOICE', invoice_on: Date.current,
                                 shipping_cost: 10, tax_cost: 5, other_cost: 0, invoice_total: cost + 15)
    unit = create(:equipment_item, application: application, purchase_order: po, funding_source: 'icanconnect',
                                   unit_cost: cost, shipped_at: Date.current, tracking_number: 'ACTUAL-SHIPMENT', delivered_on: Date.current)
    po.financial_document.attach(icc_blob)
    [po.reload, unit.reload]
  end

  def filing_selection(record)
    row = Icanconnect::FilingPrep.row(record.reload)
    { 'key' => row.key, 'lock_version' => record.lock_version.to_s, 'review_version' => row.review_version }
  end
end
