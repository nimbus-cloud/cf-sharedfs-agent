class AddUserInfo < ActiveRecord::Migration
  def self.up
    add_column :services, :username, :string
    add_column :services, :uid, :string
  end

  def self.down
    remove_column :services, :username
    remove_column :services, :uid
  end
end
