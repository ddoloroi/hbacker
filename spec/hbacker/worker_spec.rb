require File.join(File.dirname(__FILE__), "..", "spec_helper")

require "hbacker"

describe Hbacker, "queue_table_export Stalker job" do
  before :all do
    # Just enough code to execute the worker job in the scope of the test
    module Stalker
      extend self
      def log(str) end
        def job(j, &block)
          @@handler = {}
          @@handler[j] = block
        end
        def error(&blk)
        end
        def handler
          @@handler
        end
      end

      @args = {
        :table_name => "furtive_production_consumer_events_00b2330f-d66e-0e38-a6bf-0c2b529a36a2",
        :start_time => 1288537130080,
        :end_time => 1291233436567,
        :destination => "s3n://somebucket/#{@table_name}/",
        :versions => 100000,
        :backup_name => "20110101_111111",
        :stargate_url => "http://example.com",
        :aws_access_key_id => 'aws_access_key_id',
        :aws_secret_access_key => 'aws_secret_access_key',
        :hbase_name => "hbase_master0",
        :hbase_host => 'hbase-master0-production.runa.com',
        :hbase_port => 8888,
        :hbase_home => "/mnt/hbase",
        :hadoop_home =>"/mnt/hadoop"
      }
    end
    
    before :each do
      # Can not do mocks in before :all
      @hbase_mock = mock('@hbase_mock')
      @db_mock = mock('@db_mock')
      Hbacker::Db.stub(:new).and_return(@db_mock)
      @export_mock = mock('@export_mock')
      Hbacker::Export.stub(:new).and_return(@export_mock)
    end

    it "should build a proper Hbacker::Export#table command" do

      @export_mock.should_receive(:table).with(@args[:table_name], @args[:start_time], @args[:end_time], @args[:destination], 
        @args[:versions], @args[:backup_name])
      
      # This require evaluates the worker job using the module Stalker definition of job
      
      require File.expand_path(File.join(File.dirname(__FILE__), "../../", "lib", "worker"))  
      Stalker.handler['queue_table_export'].call(@args)
    end
  end