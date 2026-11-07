# frozen_string_literal: true

require 'pagy/extras/overflow'
require 'pagy/extras/array' # Add this to handle array pagination

Pagy::DEFAULT[:limit] = 20
Pagy::DEFAULT[:overflow] = :last_page
