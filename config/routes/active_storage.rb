# frozen_string_literal: true

# The application serves documents only through its authorized proxy readers.
scope ActiveStorage.routes_prefix do
  get '/blobs/proxy/:signed_id/*filename', to: 'attachment_downloads#show', as: :rails_service_blob_proxy

  get '/representations/proxy/:signed_blob_id/:variation_key/*filename',
      to: 'attachment_downloads#representation', as: :rails_blob_representation_proxy
end

direct(:rails_blob) { |model, options| route_for(:rails_storage_proxy, model, options) }
direct(:rails_representation) { |model, options| route_for(:rails_storage_proxy, model, options) }

%w[ActiveStorage::Blob ActiveStorage::Attachment ActiveStorage::Variant ActiveStorage::VariantWithRecord ActiveStorage::Preview].each do |type|
  resolve(type) { |model, options| route_for(:rails_storage_proxy, model, options) }
end

direct :rails_storage_proxy do |model, options|
  expires_in = options.delete(:expires_in) { ActiveStorage.urls_expire_in }
  expires_at = options.delete(:expires_at)
  if model.respond_to?(:signed_id)
    route_for(:rails_service_blob_proxy, model.signed_id(expires_in: expires_in, expires_at: expires_at), model.filename, options)
  else
    route_for(:rails_blob_representation_proxy, model.blob.signed_id(expires_in: expires_in, expires_at: expires_at),
              model.variation.key, model.blob.filename, options)
  end
end
