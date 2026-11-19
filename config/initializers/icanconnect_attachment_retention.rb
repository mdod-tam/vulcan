# frozen_string_literal: true

ActiveSupport.on_load(:active_storage_attachment) do
  prepend Icanconnect::RetainedAttachment
end
