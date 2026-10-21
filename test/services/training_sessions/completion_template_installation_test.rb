# frozen_string_literal: true

require 'test_helper'
require_relative '../../../db/migrate/20261020121000_install_training_completed_email_templates'

module TrainingSessions
  class CompletionTemplateInstallationTest < ActiveSupport::TestCase
    NAME = 'training_session_notifications_training_completed'

    test 'migration and repeated seed installation create each missing locale and preserve administrator edits and controls' do
      EmailTemplate.where(name: NAME).destroy_all
      assert_difference -> { EmailTemplate.where(name: NAME, format: :text).count }, 2 do
        InstallTrainingCompletedEmailTemplates.new.up
      end
      template = EmailTemplate.find_by!(name: NAME, locale: 'en', format: :text)
      template.update!(description: 'Administrator description', body: "#{template.body}\nAdministrator closing.")
      template.email_control_write = true
      template.update!(enabled: false)
      attributes = template.reload.attributes

      2.times do
        InstallTrainingCompletedEmailTemplates.new.up
        load Rails.root.join("db/seeds/email_templates/#{NAME}.rb")
        load Rails.root.join("db/seeds/email_templates/#{NAME}_es.rb")
      end

      assert_equal attributes, template.reload.attributes
      assert_equal %w[en es], EmailTemplate.where(name: NAME, format: :text).order(:locale).pluck(:locale)
      assert_equal [], template.optional_variables
      assert_equal %w[header_text recipient_full_name constituent_full_name trainer_full_name completed_date_formatted completed_time_formatted report_access_text report_url footer_text], template.required_variables
    end

    test 'completion templates refuse private and unknown placeholders in Standard and Liquid runtime rendering' do
      load_seeded_email_templates(NAME)
      template = EmailTemplate.find_by!(name: NAME, locale: 'en', format: :text)
      %w[internal_notes constituent_summary cancellation_reason no_show_notes private_notes unknown].each do |name|
        { legacy_percent: "%<#{name}>s", liquid: "{{ #{name} }}" }.each do |syntax, placeholder|
          template.assign_attributes(syntax: syntax, body: placeholder, subject: 'Confirmation')
          assert_not template.valid?, "#{syntax} accepted #{name}"
          error = assert_raises(ArgumentError) { template.render(**{}) }
          assert_includes error.message, 'not available for this template'
        end
      end
    end

    test 'migration snapshots match the seeded public completion guidance contract in each locale' do
      EmailTemplate.where(name: NAME).destroy_all
      InstallTrainingCompletedEmailTemplates.new.up
      fields = %w[subject description body variables version syntax enabled]
      installed = EmailTemplate.where(name: NAME, format: :text).order(:locale).map { |template| template.attributes.slice('locale', *fields) }

      load_seeded_email_templates(NAME)

      seeded = EmailTemplate.where(name: NAME, format: :text).order(:locale).map { |template| template.attributes.slice('locale', *fields) }
      assert_equal installed, seeded
    end
  end
end
