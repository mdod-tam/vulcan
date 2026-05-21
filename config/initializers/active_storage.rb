# frozen_string_literal: true

# Proof/document previews in admin (inline disposition). Matches ProofUploadFormats; does not control upload validation.
Rails.application.config.after_initialize do
  Rails.application.config.active_storage.content_types_allowed_inline = ProofUploadFormats::ALLOWED_CONTENT_TYPES
end

# Serve attachments through the app proxy (not redirect) for consistent caching/headers
Rails.application.config.active_storage.resolve_model_to_route = :rails_storage_proxy

# Enable Rails' built-in direct upload functionality
# This automatically:
# - Mounts the direct upload endpoint at /rails/active_storage/direct_uploads
# - Handles CSRF protection
# - Manages blob creation and direct upload URLs
# - Provides consistent behavior across the application
Rails.application.config.active_storage.direct_upload = true
