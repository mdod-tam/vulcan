# frozen_string_literal: true

module Reports
  module StaffNames
    def self.for(ids)
      names = User.where(id: ids.uniq).select(:id, :first_name, :last_name).to_h { |user| [user.id, user.full_name] }
      duplicate_names = names.values.tally
      names.to_h do |id, name|
        [id, duplicate_names[name] > 1 ? "#{name} (#{id})" : name]
      end
    end
  end
end
