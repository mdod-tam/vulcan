module Admin
  class FeatureFlagsController < BaseController
    def index
      @feature_flags = FeatureFlag.all
    end
    def update
      @feature_flag = FeatureFlag.find(params[:id])
      @feature_flag.update!(feature_flag_params)
      redirect_to admin_feature_flags_path, notice: 'Feature flag updated successfully'
    end
    private
    def feature_flag_params
      params.require(:feature_flag).permit(:enabled)
    end
  end
end
