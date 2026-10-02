# frozen_string_literal: true

require 'test_helper'

# A new attachment cannot ship without the model backstop. Only documents the application
# generates itself, never ones a person uploads, are exempt.
class DocumentAttachmentPolicyTest < ActiveSupport::TestCase
  APP_GENERATED = { 'PrintQueueItem' => %w[pdf_letter] }.freeze

  test 'every uploadable attachment declares a document policy' do
    Rails.application.eager_load!
    checked = []

    ApplicationRecord.descendants.each do |model|
      model.reflect_on_all_attachments.each do |reflection|
        name = reflection.name.to_s
        next if APP_GENERATED.fetch(model.name, []).include?(name)

        checked << "#{model.name}##{name}"
        assert model.validators_on(reflection.name).any?(DocumentValidator),
               "#{model.name}##{name} needs `validates :#{name}, document: { purpose: ... }`"
      end
    end

    assert_includes checked, 'Application#medical_certification'
    assert_includes checked, 'Users::Vendor#w9_form'
  end
end
