class AddGroupInfo < ActiveRecord::Migration
  def self.up
    add_column :services, :gid, :string
  end

  def self.down
    remove_column :services, :gid
  end
end
