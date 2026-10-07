# frozen_string_literal: true

# A date attribute people type into a text field. Readable input is stored as the date
# DateInputNormalizer reads it as. Unreadable input is never stored; it is kept on the instance as
# rejected_<attribute>_input, so a re-rendered form shows what was typed, and makes the record invalid.
module TypedDateInput
  extend ActiveSupport::Concern

  class_methods do
    def typed_date_input(attribute)
      rejected_input = :"rejected_#{attribute}_input"
      attr_reader rejected_input

      define_method(:"#{attribute}=") do |value|
        date = DateInputNormalizer.normalize(value)
        instance_variable_set(:"@#{rejected_input}", date.nil? && value.present? ? value.to_s : nil)
        super(date)
      end

      validate { errors.add(attribute, :invalid) if public_send(rejected_input) }
    end
  end
end
