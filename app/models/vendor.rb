# frozen_string_literal: true

# Top-level +Vendor+ constant for +Users::Vendor+. Unlike the other top-level user constants,
# it is a subclass rather than an alias.
require_dependency 'users/vendor'

class Vendor < Users::Vendor
end
