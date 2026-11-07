# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module ConstituentPortal
  # Spanish strings are longer than the English ones, and the card keeps its age beside the description on one row.
  class DashboardActivityTest < ApplicationSystemTestCase
    include SystemTestEvidence

    test 'the Recent Activity card reads in the viewer language' do
      user = create(:constituent, :with_disabilities, locale: 'es')
      application = create(:application, :in_progress, user: user)
      Event.create!(action: 'income_proof_attached', user: user, auditable: application,
                    metadata: { proof_type: 'income', submission_method: 'secure_form' }, created_at: 3.hours.ago)
      create(:proof_review, application: application, admin: create(:admin), proof_type: 'residency', status: 'rejected',
                            rejection_reason: 'La imagen está borrosa', created_at: 1.hour.ago)
      sign_in(user)

      visit constituent_portal_dashboard_path

      assert_selector 'h3', text: 'Actividad reciente'
      assert_text 'Comprobante de ingresos adjuntado mediante un formulario seguro'
      assert_text 'Comprobante de residencia en Maryland rechazado'
      assert_text 'Motivo: "La imagen está borrosa"'
      assert_text 'hace alrededor de 3 horas'
      assert_no_text 'Recent Activity'
      take_evidence_screenshot('dashboard-activity-es', full: true, html: true)
    end
  end
end
