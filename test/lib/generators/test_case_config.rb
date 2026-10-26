# frozen_string_literal: true

# Helper module to configure generator test cases
module TestCaseConfig
  # Sets up the destination root for generators test cases
  def self.configure_generator_test_case(klass)
    root_path = File.expand_path('tmp/generator_test_root', Rails.root)
    FileUtils.mkdir_p(root_path)

    klass.class_eval do
      # Override destination_root method to always return the correct path
      define_method(:destination_root) do
        root_path
      end

      # Override the check method to always return true
      define_method(:destination_root_is_set?) do
        true
      end

      setup do
        @destination_root = root_path
      end
    end
  end
end
