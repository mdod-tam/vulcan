# frozen_string_literal: true

# Resolves an unqualified User STI type such as "Administrator" to its Users:: class.
# This initializer changes only reads. Top-level bridge constants in app/models/ (for example admin.rb) handle the rest.
ActiveSupport.on_load(:active_record) do
  ActiveRecord::Base.singleton_class.class_eval do
    alias_method :original_sti_name_to_class, :sti_name_to_class if method_defined?(:sti_name_to_class)

    private

    def sti_name_to_class(type_name)
      return original_sti_name_to_class(type_name) unless type_name.is_a?(String)

      if type_name.exclude?('::') &&
         (name == 'User' || ancestors.map(&:name).include?('User'))
        # Order: Users::<type>, then top-level <type>, then the Rails default.
        begin
          "Users::#{type_name}".constantize
        rescue NameError
          begin
            type_name.constantize
          rescue NameError
            original_sti_name_to_class(type_name)
          end
        end
      else
        original_sti_name_to_class(type_name)
      end
    end
  end
end
