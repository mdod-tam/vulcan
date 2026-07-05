# frozen_string_literal: true

require 'test_helper'

class PaperQuickCreatePortalMarkersTest < ActiveSupport::TestCase
  FakeUser = Struct.new(:id, :email_backed) do
    def email_backed_public_portal_account?
      email_backed
    end
  end

  class DummyController
    include PaperQuickCreatePortalMarkers

    attr_accessor :session

    def initialize
      @session = {}
    end
  end

  setup do
    @controller = DummyController.new
  end

  test 'read preserves user id marker until clear' do
    @controller.store_quick_created_portal_user_marker!(portal_user(42))

    assert_equal ['42'], @controller.quick_created_portal_user_ids
    assert_equal ['42'], @controller.quick_created_portal_user_ids

    stored_entry = @controller.session[PaperQuickCreatePortalMarkers::SESSION_KEY]['42']
    assert_equal ['stored_at'], stored_entry.keys

    @controller.clear_quick_created_portal_user_markers!
    assert_empty @controller.quick_created_portal_user_ids
  end

  test 'does not store marker for non-email-backed user' do
    @controller.store_quick_created_portal_user_marker!(FakeUser.new(99, false))

    assert_empty @controller.quick_created_portal_user_ids
  end

  test 'prunes expired entries on read' do
    @controller.store_quick_created_portal_user_marker!(portal_user(99))

    travel PaperQuickCreatePortalMarkers::PAPER_QUICK_CREATE_PORTAL_MARKER_TTL + 1.minute do
      assert_empty @controller.quick_created_portal_user_ids
    end
  end

  private

  def portal_user(id)
    FakeUser.new(id, true)
  end
end
