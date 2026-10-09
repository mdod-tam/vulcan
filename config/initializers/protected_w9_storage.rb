# frozen_string_literal: true

Rails.application.config.to_prepare do
  [ActiveStorage::Blobs::RedirectController, ActiveStorage::Blobs::ProxyController,
   ActiveStorage::Representations::RedirectController, ActiveStorage::Representations::ProxyController].each do |controller|
    controller.prepend(ProtectedW9Storage::BlobGate) unless controller < ProtectedW9Storage::BlobGate
  end
  ActiveStorage::DiskController.prepend(ProtectedW9Storage::DiskGate) unless ActiveStorage::DiskController < ProtectedW9Storage::DiskGate
end
