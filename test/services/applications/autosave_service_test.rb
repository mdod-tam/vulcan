# frozen_string_literal: true

require 'test_helper'

module Applications
  class AutosaveServiceTest < ActiveSupport::TestCase
    setup do
      @user = FactoryBot.create(:constituent)
      @dependent = FactoryBot.create(:constituent, first_name: 'Dependent', last_name: 'Child')
      FactoryBot.create(:guardian_relationship, guardian_user: @user, dependent_user: @dependent)
    end

    test 'creates a new draft application when none exists' do
      assert_difference -> { Application.count }, 1 do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            field_name: 'application[household_size]',
            field_value: '3'
          }
        ).call

        assert result[:success]
        assert_not_nil result[:application_id]
      end
    end

    test 'reuses existing draft application instead of creating duplicate' do
      # Create initial draft
      existing_draft = FactoryBot.create(:application, :draft, user: @user)

      # Simulate multiple rapid autosave requests (race condition)
      assert_no_difference -> { Application.count } do
        3.times do
          result = Applications::AutosaveService.new(
            current_user: @user,
            params: {
              field_name: 'application[household_size]',
              field_value: '3'
            }
          ).call

          assert result[:success]
          assert_equal existing_draft.id, result[:application_id]
        end
      end
    end

    test 'creates new draft when no id provided and no existing draft' do
      assert_difference -> { Application.count }, 1 do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            field_name: 'application[annual_income]',
            field_value: '25000'
          }
        ).call

        assert result[:success]
        assert_not_nil result[:application_id]

        app = Application.find(result[:application_id])
        assert_equal 'draft', app.status
        assert_equal @user.id, app.user_id
        assert_nil app.managing_guardian_id
      end
    end

    test 'reuses existing draft on multiple concurrent autosaves without id' do
      # Simulate the race condition: multiple requests fired before first returns with ID
      results = []

      assert_difference -> { Application.count }, 1 do
        5.times do
          results << Applications::AutosaveService.new(
            current_user: @user,
            params: {
              field_name: 'application[household_size]',
              field_value: '2'
            }
          ).call
        end
      end

      # All should succeed and return the SAME application_id
      application_ids = results.map { |r| r[:application_id] }
      assert_equal 1, application_ids.uniq.size, 'Should only create one application'
      assert results.all? { |r| r[:success] }, 'All autosaves should succeed'
    end

    test 'finds existing draft for dependent application' do
      existing_draft = FactoryBot.create(
        :application,
        :draft,
        user: @dependent,
        managing_guardian_id: @user.id
      )

      assert_no_difference -> { Application.count } do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            user_id: @dependent.id,
            field_name: 'application[household_size]',
            field_value: '3'
          }
        ).call

        assert result[:success]
        assert_equal existing_draft.id, result[:application_id]
      end
    end

    test 'creates separate drafts for self vs dependent applications' do
      # Create draft for self
      self_draft = FactoryBot.create(:application, :draft, user: @user)

      # Autosave for dependent should create NEW draft (not reuse self draft)
      assert_difference -> { Application.count }, 1 do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            user_id: @dependent.id,
            field_name: 'application[household_size]',
            field_value: '3'
          }
        ).call

        assert result[:success]
        assert_not_equal self_draft.id, result[:application_id]

        dependent_app = Application.find(result[:application_id])
        assert_equal @dependent.id, dependent_app.user_id
        assert_equal @user.id, dependent_app.managing_guardian_id
      end
    end

    test 'updates existing draft with new field value' do
      existing_draft = FactoryBot.create(:application, :draft, user: @user, household_size: 2)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          field_name: 'application[household_size]',
          field_value: '5'
        }
      ).call

      assert result[:success]
      assert_equal existing_draft.id, result[:application_id]
      assert_equal 5, existing_draft.reload.household_size
    end

    test 'uses provided id when present' do
      draft = FactoryBot.create(:application, :draft, user: @user)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          id: draft.id,
          field_name: 'application[annual_income]',
          field_value: '30000'
        }
      ).call

      assert result[:success]
      assert_equal draft.id, result[:application_id]
    end

    test 'falls back to find_or_create when provided id not found' do
      existing_draft = FactoryBot.create(:application, :draft, user: @user)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          id: 99_999, # Non-existent ID
          field_name: 'application[household_size]',
          field_value: '3'
        }
      ).call

      assert result[:success]
      # Should find the existing draft instead of creating new
      assert_equal existing_draft.id, result[:application_id]
    end

    test 'does not reuse submitted applications' do
      submitted_app = FactoryBot.create(:application, :in_progress, user: @user)

      assert_difference -> { Application.count }, 1 do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            field_name: 'application[household_size]',
            field_value: '3'
          }
        ).call

        assert result[:success]
        assert_not_equal submitted_app.id, result[:application_id]
      end
    end

    test 'handles user disability fields correctly' do
      draft = FactoryBot.create(:application, :draft, user: @user)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          field_name: 'application[hearing_disability]',
          field_value: 'true'
        }
      ).call

      assert result[:success]
      assert_equal draft.id, result[:application_id]
      assert @user.reload.hearing_disability
    end

    test 'ignores address fields as documented' do
      FactoryBot.create(:application, :draft, user: @user)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          field_name: 'application[physical_address_1]',
          field_value: '123 Main St'
        }
      ).call

      assert_not result[:success]
      assert result[:errors].present?
    end

    test 'validates field values appropriately' do
      FactoryBot.create(:application, :draft, user: @user)

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          field_name: 'application[annual_income]',
          field_value: 'invalid'
        }
      ).call

      assert_not result[:success]
      assert result[:errors].present?
    end
  end
end
