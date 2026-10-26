# frozen_string_literal: true

require 'test_helper'

module ProductResources
  class WriterTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @product = create(:product, :archived)
    end

    test 'PDF intake enforces detected content and inclusive ten megabyte limit without broadening other purposes' do
      resource = @product.product_resources.new
      writer = ProductResources::Writer.new(resource: resource, actor: @admin)
      assert writer.save(attributes: { title: 'Guide', locale: 'en' }, source: 'pdf', document: pdf_blob(10.megabytes))
      assert_equal 10.megabytes, resource.document.blob.byte_size
      assert_equal :product_resource, UploadedDocument.declared_purpose(ProductResource, :document)
      assert_not ProofUploadFormats.size_allowed?(:w9, 10.megabytes)
      assert_not ProofUploadFormats.allowed_content_type?('image/png', purpose: :product_resource)
      assert ProofUploadFormats.allowed_content_type?('image/png', purpose: :proof)

      oversized = @product.product_resources.new
      assert_not ProductResources::Writer.new(resource: oversized, actor: @admin).save(
        attributes: { title: 'Too big', locale: 'en' }, source: 'pdf', document: pdf_blob(10.megabytes + 1)
      )
      assert oversized.errors[:document].present?
      disguised = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 2000}".b), filename: 'image.pdf', content_type: 'application/pdf')
      resource = @product.product_resources.new
      assert_not ProductResources::Writer.new(resource: resource, actor: @admin).save(
        attributes: { title: 'Not PDF', locale: 'en' }, source: 'pdf', document: disguised
      )
      assert resource.errors[:document].present?
      plain = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('not a PDF document'), filename: 'fake.pdf', content_type: 'application/pdf')
      assert_not ProductResources::Writer.new(resource: @product.product_resources.new, actor: @admin).save(
        attributes: { title: 'Disguised text', locale: 'en' }, source: 'pdf', document: plain
      )
    end

    test 'failed replacement keeps persisted attributes and original PDF while retaining an accepted replacement' do
      resource = create_pdf_resource
      original = resource.document.blob
      replacement = pdf_blob(2048)
      writer = ProductResources::Writer.new(resource: resource, actor: @admin)
      assert_no_difference 'Event.where(action: "product_resource_updated").count' do
        assert_not writer.save(attributes: { title: '', locale: 'es' }, source: 'pdf', document: replacement.signed_id)
      end
      assert_equal replacement, writer.accepted_document
      assert resource.errors[:title].present?
      assert_equal original.id, ProductResource.find(resource.id).document.blob.id
      assert original.service.exist?(original.key)
      assert_equal 'Guide', ProductResource.find(resource.id).title

      assert ProductResources::Writer.new(resource: ProductResource.find(resource.id), actor: @admin).save(
        attributes: { title: 'Guía', locale: 'es' }, source: 'pdf', document: writer.accepted_document.signed_id
      )
      assert_equal replacement.id, resource.reload.document.blob.id
    end

    test 'source switching is atomic and audit retains only structural facts attached to product' do
      resource = create_pdf_resource
      original = resource.document.blob
      writer = ProductResources::Writer.new(resource: resource, actor: @admin)
      assert_not writer.save(attributes: { title: 'Link guide', locale: 'en', url: 'javascript:alert(1)' }, source: 'url')
      assert_equal original.id, ProductResource.find(resource.id).document.blob.id
      resource.reload
      assert writer.save(attributes: { title: 'Link guide', locale: 'en', url: 'https://example.org/guide?private=sentinel' }, source: 'url')
      assert_not resource.reload.document.attached?
      event = Event.where(action: 'product_resource_updated', auditable: @product).order(:id).last
      assert_equal resource.id, event.metadata['product_resource_id']
      assert_equal 'url', event.metadata['source_type']
      assert_includes event.metadata['changed_fields'], 'url'
      assert_not_includes event.metadata.to_json, 'sentinel'

      assert_difference 'Event.where(action: "product_resource_deleted").count', 1 do
        writer.destroy!
      end
      assert_not ProductResource.exists?(resource.id)
      assert Event.exists?(action: 'product_resource_deleted', auditable: @product)
    end

    test 'an audit failure rolls back the resource and attachment change' do
      resource = create_pdf_resource
      original = resource.document.blob
      AuditEventService.stub(:log, ->(**) { raise 'audit unavailable' }) do
        assert_raises(RuntimeError) do
          ProductResources::Writer.new(resource: resource, actor: @admin).save(
            attributes: { title: 'Replacement', locale: 'en' }, source: 'pdf', document: pdf_blob(2048)
          )
        end
      end
      assert_equal 'Guide', resource.reload.title
      assert_equal original.id, resource.document.blob.id
      assert original.service.exist?(original.key)
    end

    private

    def create_pdf_resource
      resource = @product.product_resources.new
      assert ProductResources::Writer.new(resource: resource, actor: @admin).save(
        attributes: { title: 'Guide', locale: 'en' }, source: 'pdf', document: pdf_blob(1024)
      )
      resource
    end

    def pdf_blob(size)
      bytes = "%PDF-1.4\n"
      bytes += 'x' * (size - bytes.bytesize)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'guide.pdf', content_type: 'application/pdf')
      mark_document_clean!(blob, user: @admin, purpose: :product_resource, slot: 'document')
    end
  end
end
