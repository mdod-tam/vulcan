# frozen_string_literal: true

module ProtectedW9Storage
  module BlobGate
    private

    def set_blob
      super
      head :not_found if !performed? && Vendors::W9Document.protected?(@blob)
    end
  end

  module DiskGate
    def show
      key = decode_verified_key
      return head :not_found if key && Vendors::W9Document.protected_key?(key[:key])

      super
    end
  end
end
