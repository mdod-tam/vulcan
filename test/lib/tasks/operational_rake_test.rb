# frozen_string_literal: true

require 'test_helper'
require 'rake'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require 'json'

class OperationalRakeTest < ActiveSupport::TestCase
  setup do
    @original_root = Rails.root
    @original_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    %w[features email_templates_audit email_delivery vouchers notification_tracking].each do |file|
      load Rails.root.join("lib/tasks/#{file}.rake")
    end
  end

  teardown { Rake.application = @original_rake }

  test 'general feature commands change the named flag but cannot bypass communication controls' do
    flag = FeatureFlag.find_by!(name: 'vouchers_enabled')
    [['features:enable', true, 'ENABLED'], ['features:disable', false, 'DISABLED']].each do |task, enabled, label|
      capture_io { invoke(task, flag.name) }
      assert_equal enabled, flag.reload.enabled
      output, = capture_io { invoke('features:list') }
      assert_match(/vouchers_enabled\s+#{label}/, output)
    end

    before = control_snapshot
    assert_raises(ActiveRecord::RecordInvalid) { invoke('features:disable', EmailDelivery::GLOBAL_CONTROL) }
    assert_equal before, control_snapshot
  end

  test 'invalid operator arguments exit unsuccessfully without changing controls or recording audits' do
    before = control_snapshot
    assert_no_difference 'Event.count' do
      [['features:enable', nil], ['features:disable', nil],
       ['email_delivery:set_global', 'maybe'], ['email_delivery:set_all', 'maybe']].each do |task, argument|
        capture_io do
          error = assert_raises(SystemExit) { invoke(task, argument) }
          assert_equal 1, error.status
        end
      end
    end
    assert_equal before, control_snapshot
  end

  test 'release commands change only their selected control and attribute each change to the system actor' do
    actor = ensure_system_audit_actor!
    other_controls = FeatureFlag.where.not(name: [EmailDelivery::GLOBAL_CONTROL, EmailDelivery::ALL_CONTROL])
    before = other_controls.order(:name).pluck(:name, :enabled, :delivery_generation)

    [['email_delivery:set_global', EmailDelivery::GLOBAL_CONTROL, 'rake-set-global:'],
     ['email_delivery:set_all', EmailDelivery::ALL_CONTROL, 'rake-set-all:']].each do |task, control_name, operation_prefix|
      control = FeatureFlag.find_by!(name: control_name)
      generation = control.delivery_generation
      assert_difference -> { Event.where(action: EmailDelivery::ControlWriter::AUDIT_ACTION, auditable: control).count }, 2 do
        %w[off on].each do |state|
          capture_io { invoke(task, state) }
          assert_equal state == 'on', control.reload.enabled
        end
      end
      assert_equal generation + 1, control.reload.delivery_generation
      events = Event.where(action: EmailDelivery::ControlWriter::AUDIT_ACTION, auditable: control).order(:id).last(2)
      assert_equal [actor.id], events.map(&:user_id).uniq
      assert(events.all? { |event| event.metadata.fetch('operation_id').start_with?(operation_prefix) })
    end

    assert_equal before, other_controls.order(:name).pluck(:name, :enabled, :delivery_generation)
  end

  test 'a missing configured audit actor refuses release changes and never provisions an account' do
    actor = ensure_system_audit_actor!
    Current.set(user: actor) { actor.update!(email: 'not-the-configured-audit-actor@example.test') }
    before = control_snapshot

    assert_no_difference ['User.count', 'Event.count'] do
      [['email_delivery:set_global', 'off'], ['email_delivery:set_all', 'off'],
       ['email_delivery:reconcile_template_pairs'], ['email_delivery:reconcile_letters']].each do |task, *arguments|
        _output, error_output = capture_io do
          error = assert_raises(SystemExit) { invoke(task, *arguments) }
          assert_equal 1, error.status
        end
        assert_includes error_output, PublicAuditActor::SYSTEM_AUDIT_EMAIL
      end
    end
    assert_equal before, control_snapshot
  end

  test 'template audit reports real missing and unexpected keys with a nonzero exit without repairing records' do
    output = nil
    assert_no_difference ['EmailTemplate.count', 'Event.count'] do
      output, = capture_io { invoke('email_templates:audit') }
    end
    assert_includes output, 'Audit finished: OK.'

    missing = EmailTemplate.order(:id).first
    missing_key = [missing.name, missing.locale, missing.format]
    missing.destroy!
    unexpected = create(:email_template, :text, name: 'unexpected_operator_audit_probe')
    ids = EmailTemplate.order(:id).pluck(:id)
    output, = capture_io do
      assert_no_difference 'Event.count' do
        error = assert_raises(SystemExit) { invoke('email_templates:audit') }
        assert_equal 1, error.status
      end
    end

    assert_includes output, "#{missing_key[0]} (#{missing_key[1]}/#{missing_key[2]})"
    assert_includes output, 'unexpected_operator_audit_probe / en / text'
    assert_equal ids, EmailTemplate.order(:id).pluck(:id)
    assert_not EmailTemplate.exists?(missing.id)
    assert_equal 'unexpected_operator_audit_probe', unexpected.reload.name
  end

  test 'missing voucher report scopes current workflow and proof readiness without issuing vouchers' do
    equipment = create(:application, :approved, disability_certification_status: :approved)
    FeatureFlag.enable!(:vouchers_enabled)
    ready = create(:application, :approved, disability_certification_status: :approved, income_proof_status: :not_reviewed)
    issued = create(:application, :approved, disability_certification_status: :approved)
    create(:voucher, application: issued, vendor: nil)
    wrong_status = create(:application, :in_progress,
                          residency_proof_status: :approved, id_proof_status: :approved, disability_certification_status: :approved)
    missing_proofs = %i[residency_proof_status id_proof_status disability_certification_status].map do |field|
      attributes = { residency_proof_status: :approved, id_proof_status: :approved, disability_certification_status: :approved }
      attributes[field] = field == :disability_certification_status ? :not_requested : :not_reviewed
      create(:application, :approved, **attributes)
    end

    output = nil
    assert_no_difference ['Voucher.count', 'Event.count'] do
      output, = capture_io { invoke('vouchers:report_missing') }
    end
    reported = output.scan(/^Application ID: (\d+),/).flatten.map(&:to_i)
    assert_includes reported, ready.id
    [equipment, issued, wrong_status, *missing_proofs].each { |application| assert_not_includes reported, application.id }
  end

  test 'notification tracking queues the bounded poll owner without changing notification history' do
    application = create(:application)
    create(:notification, notifiable: application, recipient: application.user, actor: application.user,
                          action: 'disability_certification_requested')
    before = Notification.order(:id).pluck(:id, :delivery_status, :metadata)
    assert_no_difference 'Event.count' do
      assert_enqueued_with(job: EmailDelivery::PollJob) do
        output, = capture_io { invoke('notification_tracking:check_all') }
        assert_includes output, 'Queued a bounded delivery check.'
      end
    end
    assert_equal before, Notification.order(:id).pluck(:id, :delivery_status, :metadata)
  end

  test 'test CSS task invokes the local binary without install and refuses a missing binary' do
    Dir.mktmpdir('local-tailwind-task') do |directory|
      root = Pathname.new(directory)
      binary = root.join('node_modules/.bin/tailwindcss')
      FileUtils.mkdir_p(binary.dirname)
      File.write(binary, <<~SCRIPT)
        #!#{RbConfig.ruby}
        require 'json'
        File.write(#{root.join('arguments.json').to_s.inspect}, JSON.generate(ARGV))
        File.write(ARGV.fetch(ARGV.index('-o') + 1), 'generated-css')
      SCRIPT
      File.chmod(0o755, binary)
      Rake::Task.define_task('css:install') { flunk 'test CSS build must not install packages' }
      Rake::Task.define_task('css:build' => 'css:install') { flunk 'replaced CSS action ran' }

      Rails.stub(:root, root) do
        load @original_root.join('lib/tasks/skip_cssbundling_install_in_test.rake')
        capture_io { invoke('css:build') }
        assert_equal ['-i', root.join('app/assets/stylesheets/application.tailwind.css').to_s,
                      '-o', root.join('app/assets/builds/application.css').to_s, '--minify'], JSON.parse(root.join('arguments.json').read)
        assert_equal 'generated-css', root.join('app/assets/builds/application.css').read
        File.delete(binary)
        capture_io do
          error = assert_raises(SystemExit) { invoke('css:build') }
          assert_equal 1, error.status
        end
      end
    end
  end

  private

  def invoke(name, *)
    Rake::Task[name].reenable
    Rake::Task[name].invoke(*)
  end

  def control_snapshot
    FeatureFlag.order(:name).pluck(:name, :enabled, :delivery_generation)
  end
end
