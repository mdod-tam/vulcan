# frozen_string_literal: true

module ConstituentPortal
  module ActivityHelper
    # Classes for the round icon beside an activity: info color for a submission, success for an approval, danger for a rejection.
    def activity_icon_class(activity)
      base_classes = 'h-8 w-8 rounded-full flex items-center justify-center ring-8 ring-white'

      case activity.activity_type
      when :submission, :resubmission
        "#{base_classes} text-info-600"
      when :approval
        "#{base_classes} text-success-600"
      when :rejection
        "#{base_classes} text-danger-600"
      else
        "#{base_classes} text-gray-500"
      end
    end
  end
end
