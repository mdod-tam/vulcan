# frozen_string_literal: true

# Production initialization: accounts, then the baseline, in one transaction. It needs no FactoryBot and removes no demo data.
# Run it through `bin/rails db:bootstrap`, which validates input and migrates first. It overwrites staff-edited baseline data.
Baseline::Bootstrap.run!
