# frozen_string_literal: true

module Admin
  class ProductResourcesController < ApplicationController
    before_action :require_admin!
    before_action :set_product
    before_action :set_resource, only: %i[edit update destroy]

    def new
      @resource = @product.product_resources.new(locale: I18n.locale)
      @source = 'url'
    end

    def edit
      @source = @resource.source_type
      @attempted_url = @resource.url
      @retained_document = @resource.document.blob if @resource.document.attached?
    end

    def create
      @resource = @product.product_resources.new
      save_resource(:new)
    end

    def update
      save_resource(:edit)
    end

    def destroy
      ProductResources::Writer.new(resource: @resource, actor: current_user).destroy!
      redirect_to admin_product_path(@product), notice: 'Resource deleted.', status: :see_other
    end

    private

    def set_product
      @product = Product.find(params.expect(:product_id))
    end

    def set_resource
      @resource = @product.product_resources.find(params.expect(:id))
    end

    def save_resource(template)
      submitted = params.expect(product_resource: %i[title locale url source document document_signed_id])
      @source = submitted[:source]
      @attempted_url = submitted[:url]
      writer = ProductResources::Writer.new(resource: @resource, actor: current_user)
      if writer.save(attributes: submitted.slice(:title, :locale, :url), source: @source,
                     document: UploadedDocument.submitted(submitted, 'document'))
        redirect_to admin_product_path(@product), notice: 'Resource saved.', status: :see_other
      else
        @retained_document = writer.accepted_document || UploadedDocument.restorable(submitted[:document_signed_id], record: @resource, name: 'document')
        render template, status: :unprocessable_content
      end
    end
  end
end
