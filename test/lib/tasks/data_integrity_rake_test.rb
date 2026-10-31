# frozen_string_literal: true

require 'test_helper'
require 'rake'

class DataIntegrityRakeTest < ActiveSupport::TestCase
  setup do
    Rake::Task.define_task(:environment)
    load Rails.root.join('lib/tasks/data_integrity.rake') unless Rake::Task.task_defined?('data_integrity:fix_orphaned_applications')
    @application = create(:application)
    empty_query = Application.none.where
    # Simulate the maintenance query finding corrupt ownership without disabling foreign keys.
    Application.stubs(:where).with(user_id: nil).returns([@application])
    Application.stubs(:where).with.returns(empty_query)
  end

  test 'delete refuses retained history and does not report completion' do
    history = create(:certification_upload_form, application: @application)

    output, = capture_io do
      assert_raises(ActiveRecord::RecordNotDestroyed) { delete_orphans }
    end

    assert Application.exists?(@application.id)
    assert_equal @application.id, history.reload.application_id
    assert_not_includes output, 'Deletion complete.'
  end

  test 'delete reports completion only after its unprotected application is removed' do
    output = nil
    assert_difference 'Application.count', -1 do
      output, = capture_io { delete_orphans }
    end

    assert_not Application.exists?(@application.id)
    assert_includes output, 'Deletion complete.'
  end

  private

  def delete_orphans
    task = Rake::Task['data_integrity:fix_orphaned_applications']
    task.reenable
    task.invoke('delete')
  end
end
