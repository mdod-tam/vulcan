# frozen_string_literal: true

module ConstituentNamespaceHelper
  # This helper is used to load the Constituent namespace controllers
  # without conflicting with the Constituent model
  def self.load_controller(controller_path)
    original_constituent = Constituent

    Object.send(:remove_const, :Constituent) if defined?(Constituent)

    Object.const_set(:Constituent, Module.new)

    require Rails.root.join(controller_path)

    Object.send(:remove_const, :Constituent)
    Object.const_set(:Constituent, original_constituent)
  end
end
