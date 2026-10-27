# frozen_string_literal: true

# Top-level +MedicalProvider+ alias for +Users::MedicalProvider+.
require_dependency 'users/medical_provider'

MedicalProvider = Users::MedicalProvider unless defined?(MedicalProvider)
