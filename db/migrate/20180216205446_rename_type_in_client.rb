class RenameTypeInClient < ActiveRecord::Migration[5.1]
  def change
    rename_column :clients, :type, :client_type
  end
end
