# frozen_string_literal: true

# The paginated lists use paginate_or_first_page, so a bad page parameter behaves the same on each of them.
module PageRecovery
  extend ActiveSupport::Concern

  include Pagy::Backend

  private

  # A page parameter that is not a positive integer shows the first page. A pagination error about anything else
  # is a fault, so it propagates. A page past the end is already handled by Pagy's overflow setting.
  def paginate_or_first_page(scope, **)
    pagy(scope, **)
  rescue Pagy::VariableError => e
    raise unless e.variable == :page

    pagy(scope, **, page: 1)
  end
end
