# frozen_string_literal: true

# Recipient-ready queue artifacts leave only through the authenticated POST release action.
# Ordinary uploads and unattached provider fax media retain their Active Storage contract.
module PrintQueueBlobGuard
  def show
    return head :not_found if @blob && PrintQueueBlobGuard.print_letter?(@blob)

    super
  end

  def self.print_letter?(blob)
    blob.attachments.exists?(record_type: 'PrintQueueItem', name: 'pdf_letter')
  end

  module Disk
    def show
      key = decode_verified_key
      blob = ActiveStorage::Blob.find_by(key: key[:key]) if key
      return head :not_found if blob && PrintQueueBlobGuard.print_letter?(blob)

      super
    end
  end
end
