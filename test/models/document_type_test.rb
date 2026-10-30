# frozen_string_literal: true

require 'test_helper'

class DocumentTypeTest < ActiveSupport::TestCase
  ATTACHMENT_BY_TYPE = {
    income: 'income_proof',
    residency: 'residency_proof',
    id: 'id_proof',
    disability_certification: 'disability_certification'
  }.freeze

  test 'fetch accepts a symbol or a string' do
    assert_same DocumentType::INCOME, DocumentType.fetch(:income)
    assert_same DocumentType::INCOME, DocumentType.fetch('income')
  end

  test 'fetch raises for a key that is not a document type' do
    assert_raises(KeyError) { DocumentType.fetch(:passport) }
    assert_raises(KeyError) { DocumentType.fetch(nil) }
  end

  test 'the registry covers exactly the proof types a ProofReview can record' do
    assert_equal ProofReview.proof_types.keys.sort, DocumentType::ALL.map { |type| type.key.to_s }.sort
  end

  test 'every document type names an attachment declared on Application' do
    DocumentType::ALL.each do |type|
      assert Application.reflect_on_attachment(type.attachment_name), "#{type.key} names #{type.attachment_name}, which Application does not declare"
    end
  end

  test 'every rejection letter type is a print queue letter type' do
    DocumentType::ALL.each do |type|
      assert_includes PrintQueueItem.letter_types.keys, type.rejection_letter_type.to_s, "#{type.key} has no matching print queue letter type"
    end
  end

  test 'the certification has no proof-rejection letter of its own' do
    assert_equal :other_notification, DocumentType::DISABILITY_CERTIFICATION.rejection_letter_type
  end

  test 'document_attachment_for returns the attachment each type names' do
    application = build(:application)

    ATTACHMENT_BY_TYPE.each do |type, attachment_name|
      assert_equal attachment_name, application.document_attachment_for(type).name, "#{type} resolved to the wrong attachment"
    end
  end
end
