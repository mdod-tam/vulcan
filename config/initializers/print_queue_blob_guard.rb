# frozen_string_literal: true

Rails.application.config.to_prepare do
  [ActiveStorage::Blobs::RedirectController, ActiveStorage::Blobs::ProxyController,
   ActiveStorage::Representations::RedirectController, ActiveStorage::Representations::ProxyController].each do |controller|
    controller.prepend(PrintQueueBlobGuard) unless controller < PrintQueueBlobGuard
  end
  ActiveStorage::DiskController.prepend(PrintQueueBlobGuard::Disk) unless ActiveStorage::DiskController < PrintQueueBlobGuard::Disk
end
