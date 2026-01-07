module Admin
  class FeatureFlagsController < BaseController
    def index
      @feature_flags = FeatureFlag.all
    end
    def update
      @feature_flag = FeatureFlag.find(params[:id])
      @feature_flag.update!(feature_flag_params)
      AuditEventService.log(
        action: 'feature_flag_toggled',
        actor: current_user,
        auditable: @feature_flag,
        metadata: {
          flag_name: @feature_flag.name,
          old_value: !@feature_flag.enabled,
          new_value: @feature_flag.enabled,
          admin_id: current_user.id,
          admin_name: current_user.full_name
        }
      )
      redirect_to admin_feature_flags_path, notice: 'Feature flag updated successfully'
    end
    private
    def feature_flag_params
      params.require(:feature_flag).permit(:enabled)
    end
  end
end
