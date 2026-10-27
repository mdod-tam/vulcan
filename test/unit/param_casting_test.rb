# frozen_string_literal: true

require 'test_helper'

class ParamCastingTest < ActiveSupport::TestCase
  # Simple controller class to test the concern
  class TestController
    include ParamCasting

    attr_accessor :params

    def initialize(params = {})
      @params = ActionController::Parameters.new(params)
    end
  end

  def setup
    @controller = TestController.new
  end

  test 'to_boolean casts various values correctly' do
    assert_equal true, @controller.to_boolean('1')
    assert_equal true, @controller.to_boolean(1)
    assert_equal true, @controller.to_boolean('true')
    assert_equal true, @controller.to_boolean(true)

    assert_equal false, @controller.to_boolean('0')
    assert_equal false, @controller.to_boolean(0)
    assert_equal false, @controller.to_boolean('false')
    assert_equal false, @controller.to_boolean(false)
    assert_nil @controller.to_boolean('')
    assert_nil @controller.to_boolean(nil)
  end

  test 'safe_boolean_cast is an alias for to_boolean' do
    assert_equal @controller.to_boolean('1'), @controller.safe_boolean_cast('1')
    assert_equal @controller.to_boolean('0'), @controller.safe_boolean_cast('0')
  end

  test 'cast_complex_boolean_params works with nested structures' do
    @controller.params = ActionController::Parameters.new({
                                                            application: {
                                                              maryland_resident: '1'
                                                            },
                                                            applicant_attributes: {
                                                              hearing_disability: '1',
                                                              vision_disability: '0'
                                                            },
                                                            use_guardian_email: 'true',
                                                            use_guardian_phone: '0'
                                                          })

    @controller.cast_complex_boolean_params

    assert_equal true, @controller.params[:application][:maryland_resident]
    assert_equal true, @controller.params[:applicant_attributes][:hearing_disability]
    assert_equal false, @controller.params[:applicant_attributes][:vision_disability]
    assert_equal true, @controller.params[:use_guardian_email]
    assert_equal false, @controller.params[:use_guardian_phone]
  end

  test 'cast_boolean_for handles array workaround for hidden checkboxes' do
    hash = {
      hearing_disability: ['', '1'], # Rails hidden checkbox pattern
      vision_disability: '0'
    }

    @controller.send(:cast_boolean_for, hash, %w[hearing_disability vision_disability])

    assert_equal true, hash[:hearing_disability]
    assert_equal false, hash[:vision_disability]
  end
end
