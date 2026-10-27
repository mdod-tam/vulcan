# frozen_string_literal: true

# Assigns instance variables from computed names. Characters that are not valid in an
# instance variable name become underscores.
module SafeInstanceVariables
  extend ActiveSupport::Concern

  # Sets @key to value. A leading @ on key is dropped.
  # @param key [String, Symbol] The variable name
  # @param value [Object] The value to assign
  def safe_assign(key, value)
    sanitized_key = key.to_s.sub(/\A@/, '').gsub(/[^0-9a-zA-Z_]/, '_')
    instance_variable_set("@#{sanitized_key}", value)
  end

  # Calls safe_assign for each pair.
  # @param hash [Hash] Instance variable names mapped to their values
  def safe_assign_all(hash)
    hash.each do |key, value|
      safe_assign(key, value)
    end
  end
end
