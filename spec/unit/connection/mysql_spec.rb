require 'spec_helper'
require 'zlib'

describe Forklift::Connection::Mysql do

  describe "read/write utils" do
    before(:each) do
      SpecSeeds.setup_mysql
    end

    it "can read a list of tables" do
      plan = SpecPlan.new
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect(source.tables).to include 'users'
        expect(source.tables).to include 'products'
        expect(source.tables).to include 'sales'
      }
      plan.disconnect!
    end

    it "can delte a table" do 
      plan = SpecPlan.new
      table = "users"
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect(source.tables).to include 'users'
        source.drop! table
        expect(source.tables).to_not include 'users'
      }
      plan.disconnect!
    end

    it "can count the rows in a table" do
      plan = SpecPlan.new
      table = "users"
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect(source.count(table)).to eql 5
      }
      plan.disconnect!
    end

    it "can truncate a table (both with and without !)" do 
      plan = SpecPlan.new
      table = "users"
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect(source.count(table)).to eql 5
        source.truncate! table
        expect(source.count(table)).to eql 0
        expect { source.truncate(table) }.to_not raise_error
      }
      plan.disconnect!
    end

    it 'trunacte! will raise if the table does not exist' do
      plan = SpecPlan.new
      table = "other_table"
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect { source.truncate!(table) }.to raise_error(/Table 'forklift_test_source_a.other_table' doesn't exist/)
      }
      plan.disconnect!
    end

    it "can get the columns of a table" do 
      plan = SpecPlan.new
      table = "sales"
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        expect(source.columns(table)).to include 'id' 
        expect(source.columns(table)).to include 'user_id' 
        expect(source.columns(table)).to include 'product_id' 
        expect(source.columns(table)).to include 'timestamp' 
      }
      plan.disconnect!
    end

    it "can create a mysqldump" do
      dump = "/tmp/destination.sql.gz"
      plan = SpecPlan.new
      plan.do! {
        source = plan.connections[:mysql][:forklift_test_source_a]
        source.dump(dump)
      }
      plan.disconnect!

      expect(File.exists?(dump)).to eql true
      contents = Zlib::GzipReader.new(StringIO.new(File.read(dump))).read  
      expect(contents).to include "(1,'evan@example.com','Evan','T','2014-04-03 11:40:12','2014-04-03 11:39:28')"
    end

  end

  describe "#safe_values" do
    subject { described_class.new({}, {}) }

    it "escapes one trailing backslash" do
      columns = ['col']
      values = {:col => "foo\\"}
      expect(subject.send(:safe_values, columns, values)).to eq("( \"foo\\\\\" )")
    end

    it "escapes two trailing backslashes" do
      columns = ['col']
      values = {:col => "foo\\\\" }
      expect(subject.send(:safe_values, columns, values)).to eq("( \"foo\\\\\\\\\" )")
    end
  end
end