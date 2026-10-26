# frozen_string_literal: true

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.object_src :none
    policy.frame_ancestors :self
    policy.form_action :self
    policy.script_src :self
    policy.script_src_attr :none
    policy.style_src :self
    policy.img_src :self, :data, :blob
    policy.font_src :self, :data
    policy.connect_src :self
    policy.frame_src :self, :blob
    policy.worker_src :self, :blob
    policy.report_uri '/csp_reports'
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
  config.content_security_policy_report_only = false
end
