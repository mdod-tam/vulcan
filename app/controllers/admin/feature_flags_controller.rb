module Admin
  class FeatureFlagsController < BaseController
    def index
      @feature_flags = FeatureFlag.all
    end

    def update
      @feature_flag = FeatureFlag.find(params[:id])
      old_value = @feature_flag.enabled

      begin
        ActiveRecord::Base.transaction do
          @feature_flag.update!(feature_flag_params)
          AuditEventService.log(
            action: 'feature_flag_toggled',
            actor: current_user,
            auditable: @feature_flag,
            metadata: {
              flag_name: @feature_flag.name,
              old_value: old_value,
              new_value: @feature_flag.enabled,
              admin_id: current_user.id,
              admin_name: current_user.full_name
            }
          )
        end
        redirect_to admin_feature_flags_path, notice: 'Feature flag updated successfully'
      rescue StandardError => e
        redirect_to admin_feature_flags_path, alert: "Failed to update feature flag: #{e.message}"
      end
    end

    private

    def feature_flag_params
      params.expect(feature_flag: [:enabled])
    end
  end
end
