# frozen_string_literal: true

require 'test_helper'

class PaperQuickCreateTempPasswordsTest < ActiveSupport::TestCase
  class DummyController
    include PaperQuickCreateTempPasswords

    attr_accessor :session

    def initialize
      @session = {}
    end
  end

  setup do
    @controller = DummyController.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache.clear
  end

  test 'read preserves session until clear' do
    @controller.store_quick_create_temp_password!(42, 'secret123')

    assert_equal({ '42' => 'secret123' }, @controller.quick_create_temp_passwords)
    assert_equal({ '42' => 'secret123' }, @controller.quick_create_temp_passwords)
    assert_not_includes @controller.session[:paper_quick_create_temp_passwords]['42'].values, 'secret123'

    @controller.clear_quick_create_temp_passwords!
    assert_empty @controller.quick_create_temp_passwords
  end

  test 'prunes expired entries on read' do
    @controller.store_quick_create_temp_password!(99, 'oldpass')

    travel PaperQuickCreateTempPasswords::PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL + 1.minute do
      assert_empty @controller.quick_create_temp_passwords
    end
  end
end
