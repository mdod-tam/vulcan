# frozen_string_literal: true

require 'test_helper'
require_relative '../../../db/migrate/20260620120000_update_text_email_link_accessibility_copy'
require_relative '../../../db/migrate/20261020124000_install_spanish_trainer_assignment_template'

module TrainingSessions
  class TrainerAssignmentTemplateInstallationTest < ActiveSupport::TestCase
    NAME = 'training_session_notifications_trainer_assigned'
    SEED_PATH = Rails.root.join("db/seeds/email_templates/#{NAME}_es.rb")
    CONTRACT_ATTRIBUTES = %w[subject description body variables version syntax enabled].freeze

    test 'upgrade migration restores Spanish assignment after the earlier migration removes staff translations without requiring seeds' do
      EmailTemplate.where(name: NAME, format: :text, locale: 'es').destroy_all
      load SEED_PATH
      seed_contract = EmailTemplate.find_by!(name: NAME, format: :text, locale: 'es').attributes.slice(*CONTRACT_ATTRIBUTES)

      UpdateTextEmailLinkAccessibilityCopy.new.up
      assert_nil EmailTemplate.find_by(name: NAME, format: :text, locale: 'es')
      english_attributes = EmailTemplate.find_by!(name: NAME, format: :text, locale: 'en').attributes

      assert_difference -> { EmailTemplate.where(name: NAME, format: :text, locale: 'es').count }, 1 do
        InstallSpanishTrainerAssignmentTemplate.new.up
      end

      template = EmailTemplate.find_by!(name: NAME, format: :text, locale: 'es')
      assert_equal seed_contract, template.attributes.slice(*CONTRACT_ATTRIBUTES)
      assert template.valid?, template.errors.full_messages.join(', ')
      assert_equal english_attributes, EmailTemplate.find_by!(name: NAME, format: :text, locale: 'en').attributes
      assert_equal %w[en es], EmailTemplate.where(name: NAME, format: :text).order(:locale).pluck(:locale)

      trainer = create(:trainer, locale: 'es')
      session = create(:training_session, trainer: trainer)
      email = TrainingSessionNotificationsMailer.with(assignment_notice_params(session, trainer)).trainer_assigned.message
      assert_equal [trainer.email], email.to
      assert_equal seed_contract.fetch('subject'), email.subject
      assert_includes email.body.decoded, trainer.full_name
      assert_includes email.body.decoded, 'Preferencias de comunicación'
    end

    test 'repeated migration and seed installation preserve an existing administrator row and delivery settings' do
      EmailTemplate.where(name: NAME, format: :text, locale: 'es').destroy_all
      InstallSpanishTrainerAssignmentTemplate.new.up
      template = EmailTemplate.find_by!(name: NAME, format: :text, locale: 'es')
      template.email_control_write = true
      template.update!(subject: 'Asignación editada por administración',
                       description: 'Descripción editada por administración',
                       body: "#{template.required_variables.map { |variable| "{{ #{variable} }}" }.join("\n")}\nCierre de administración.",
                       syntax: :liquid, enabled: false)
      attributes = template.reload.attributes

      assert_no_difference -> { EmailTemplate.where(name: NAME, format: :text, locale: 'es').count } do
        2.times do
          InstallSpanishTrainerAssignmentTemplate.new.up
          load SEED_PATH
        end
      end

      assert_equal attributes, template.reload.attributes
      assert_raises(ActiveRecord::IrreversibleMigration) { InstallSpanishTrainerAssignmentTemplate.new.down }
      assert_equal attributes, template.reload.attributes
    end
  end
end
