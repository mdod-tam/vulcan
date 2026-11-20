# frozen_string_literal: true

module Admin
  module Icanconnect
    class SettingsController < Admin::BaseController
      include PolicyEditor

      def update
        attributes = params.expect(icanconnect_setting: [:starts_on])
        ::Icanconnect::Setting.transaction do
          setting = ::Icanconnect::Setting.find_or_create_by!(id: ::Icanconnect::Setting::ID)
          setting.lock!
          setting.update!(attributes)
          if setting.saved_change_to_starts_on?
            AuditEventService.log(action: 'icanconnect_start_date_updated', actor: current_user, auditable: setting,
                                  metadata: { operation_id: SecureRandom.uuid, changes: { starts_on: setting.saved_change_to_starts_on } })
          end
        end
        redirect_to admin_policies_path(anchor: 'icanconnect-participation'), notice: 'iCanConnect start date saved.', status: :see_other
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.is_a?(::Icanconnect::Setting)

        load_policies
        @icanconnect_setting = e.record
        render 'admin/policies/index', formats: [:html], status: :unprocessable_content
      end
    end
  end
end
