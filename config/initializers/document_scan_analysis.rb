# frozen_string_literal: true

# Both queued analysis and Rails' synchronous analysis path reach this method.
module DocumentScanAnalysisGuard
  def analyze
    return unless DocumentScan.cleared?(self)

    super
  end
end

ActiveSupport.on_load(:active_storage_blob) do
  prepend DocumentScanAnalysisGuard
end
