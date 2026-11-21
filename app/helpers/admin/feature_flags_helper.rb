# frozen_string_literal: true

module Admin
  module FeatureFlagsHelper
    def feature_flag_label(name)
      {
        'vouchers_enabled' => 'Vouchers',
        'dcf_auto_request_certification' => 'Auto-send DCF provider request'
      }.fetch(name, name.humanize.titleize)
    end
  end
end
