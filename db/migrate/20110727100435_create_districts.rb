class CreateDistricts < ActiveRecord::Migration
  def self.up
    create_table :districts do |t|

      t.timestamps
    end
  end

  def self.down
    drop_table :districts
  end
end
