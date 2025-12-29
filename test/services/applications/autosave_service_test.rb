# frozen_string_literal: true

require 'test_helper'

module Applications
  class AutosaveServiceTest < ActiveSupport::TestCase
    setup do
      # Create guardian with explicit disability settings to avoid factory defaults
      @user = FactoryBot.create(:constituent,
                                hearing_disability: false,
                                vision_disability: true)
      # Create dependent with explicit disability settings to avoid factory defaults
      @dependent = FactoryBot.create(:constituent,
                                     first_name: 'Dependent',
                                     last_name: 'Child',
                                     hearing_disability: false,
                                     vision_disability: true)
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
      application_ids = results.pluck(:application_id)
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

    test 'does not create new draft when active application exists' do
      # When user has a submitted/active application, they cannot create a new draft
      # This prevents duplicate applications and aligns with controller logic
      FactoryBot.create(:application, :in_progress, user: @user)

      assert_no_difference -> { Application.count } do
        result = Applications::AutosaveService.new(
          current_user: @user,
          params: {
            field_name: 'application[household_size]',
            field_value: '3'
          }
        ).call

        assert_not result[:success], 'Should not allow creating draft when active application exists'
        assert result[:errors].present?
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

    test 'finds dependent draft by id when guardian is current user' do
      # This tests the bug fix: searching in managed_applications when id is provided
      dependent_draft = FactoryBot.create(
        :application,
        :draft,
        user: @dependent,
        managing_guardian_id: @user.id
      )

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          id: dependent_draft.id,
          field_name: 'application[household_size]',
          field_value: '4'
        }
      ).call

      assert result[:success], "Expected autosave to succeed but got errors: #{result[:errors]}"
      assert_equal dependent_draft.id, result[:application_id]
      assert_equal 4, dependent_draft.reload.household_size
    end

    test 'updates disability fields on dependent user record not guardian' do
      # This tests the bug fix: disability fields should be saved to the dependent's record
      dependent_draft = FactoryBot.create(
        :application,
        :draft,
        user: @dependent,
        managing_guardian_id: @user.id
      )

      # Verify initial state
      assert_not @dependent.hearing_disability
      assert_not @user.hearing_disability

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          id: dependent_draft.id,
          field_name: 'application[hearing_disability]',
          field_value: 'true'
        }
      ).call

      assert result[:success], "Expected autosave to succeed but got errors: #{result[:errors]}"

      # Verify the dependent's disability flag was updated, not the guardian's
      assert @dependent.reload.hearing_disability, 'Dependent should have hearing_disability set to true'
      assert_not @user.reload.hearing_disability, 'Guardian should not have hearing_disability set'
    end

    test 'handles maryland_resident checkbox for dependent applications' do
      # This tests the bug fix: maryland_resident checkbox should work for dependent applications
      dependent_draft = FactoryBot.create(
        :application,
        :draft,
        user: @dependent,
        managing_guardian_id: @user.id,
        maryland_resident: false
      )

      result = Applications::AutosaveService.new(
        current_user: @user,
        params: {
          id: dependent_draft.id,
          field_name: 'application[maryland_resident]',
          field_value: 'true'
        }
      ).call

      assert result[:success], "Expected autosave to succeed but got errors: #{result[:errors]}"
      assert dependent_draft.reload.maryland_resident, 'maryland_resident should be set to true'
    end
  end
end
