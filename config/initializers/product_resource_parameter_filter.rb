# frozen_string_literal: true

# Public guidance links may still carry query credentials; logs retain structural fields only.
Rails.application.config.filter_parameters += ['product_resource.url', 'product_resource.document', :documentation_url]
