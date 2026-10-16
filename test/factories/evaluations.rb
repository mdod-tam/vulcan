# frozen_string_literal: true

# test/factories/evaluations.rb
FactoryBot.define do
  factory :evaluation do
    evaluator
    application factory: %i[application approved with_all_proofs]
    constituent { application.user }
    evaluation_date { 1.day.from_now }
    evaluation_type { :initial }
    status { :requested }
    notes { 'Default evaluation notes' }
    location { 'Main Office' }
    needs { 'Additional support for mobility.' }

    # Default attendees
    attendees do
      [
        { 'name' => 'John Doe', 'relationship' => 'Self' },
        { 'name' => 'Jane Smith', 'relationship' => 'Caregiver' }
      ]
    end

    # Set up default products
    after(:build) do |evaluation|
      # Create products directly
      ipad_air = create(:product, name: 'iPad Air')
      ipad_mini = create(:product, name: 'iPad Mini')

      # Set up products tried
      evaluation.products_tried = [
        { 'product_id' => ipad_air.id, 'reaction' => 'Satisfied' },
        { 'product_id' => ipad_mini.id, 'reaction' => 'Neutral' }
      ]

      # Set recommended products
      evaluation.recommended_product_ids = [ipad_air.id, ipad_mini.id]
    end

    trait :completed do
      status { :completed }
      notes { 'Evaluation completed successfully.' }
      evaluation_date { 1.day.from_now }
      appointment_completed_at { 1.hour.ago }
      report_submitted_at { Time.current }
    end

    trait :pending do
      status { :scheduled }
      notes { 'Pending evaluation notes' }
    end

    trait :with_custom_attendees do
      attendees do
        [
          { 'name' => 'Alice Johnson', 'relationship' => 'Self' }
        ]
      end
    end

    trait :with_mobile_devices do
      # Override default products after creation
      after(:create) do |evaluation|
        iphone = Product.find_or_create_by(name: 'iPhone') do |product|
          product.description = 'Smartphone with comprehensive accessibility features'
          product.manufacturer = 'Apple'
          product.model_number = 'iPhone-16'
          product.features = 'VoiceOver, Zoom, Switch Control, AssistiveTouch'
          product.compatibility_notes = 'Compatible with all iOS accessibility features'
          product.documentation_url = 'https://support.apple.com/guide/iphone'
          product.device_types = ['Smartphone']
        end

        pixel = Product.find_or_create_by(name: 'Pixel') do |product|
          product.description = 'Android smartphone with accessibility features'
          product.manufacturer = 'Google'
          product.model_number = 'Pixel-8'
          product.features = 'TalkBack, Magnification, Voice Access'
          product.compatibility_notes = 'Compatible with Android accessibility services'
          product.documentation_url = 'https://support.google.com/pixel'
          product.device_types = ['Smartphone']
        end

        evaluation.update!(
          products_tried: [
            { 'product_id' => iphone.id, 'reaction' => 'Very Satisfied' },
            { 'product_id' => pixel.id, 'reaction' => 'Satisfied' }
          ],
          recommended_product_ids: [iphone.id, pixel.id]
        )
      end
    end

    trait :with_single_product do
      after(:build) do |evaluation|
        ipad = create(:product, name: 'iPad Air')
        evaluation.products_tried = [
          { 'product_id' => ipad.id, 'reaction' => 'Very Satisfied' }
        ]
        evaluation.recommended_product_ids = [ipad.id]
      end
    end
  end
end
