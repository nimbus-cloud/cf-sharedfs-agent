class CreateServices < ActiveRecord::Migration
  def self.up
    create_table :services do |t|
      t.string       :service_id
      t.string       :plan_id
      t.string       :quota
    end
    add_index :services, :service_id
  end

  def self.down
    remove_index :services, :column => :service_id
    drop_table :services
  end
end
