# frozen_string_literal: true

# This file acts as a bridge between the Vendor constant needed for backward compatibility
# and the Users::Vendor class needed for Single Table Inheritance

# Include the actual implementation
require_dependency 'users/vendor'

# Define a proper Vendor class for STI that maintains compatibility with existing tests
class Vendor < Users::Vendor
end
