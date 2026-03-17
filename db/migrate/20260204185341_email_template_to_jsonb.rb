class EmailTemplateToJsonb < ActiveRecord::Migration[8.0]
  def up
    change_column_default :email_templates, :variables, nil
    change_column :email_templates, :variables, :jsonb, default: {}, using: <<~SQL
      jsonb_build_object(
        'required', to_jsonb(variables),
        'optional', '[]'::jsonb
      )
    SQL
    change_column_default :email_templates, :variables, {}
  end

  def down 
    change_column_default :email_templates, :variables, nil
    change_column :email_templates, :variables, :text, array: true, default: [], using: <<~SQL
      ARRAY(SELECT jsonb_array_elements_text(variables->'required'))
    SQL
    change_column_default :email_templates, :variables, []
  end
end
