module Hbacker
  require "right_aws"
  require "sdb/active_sdb"
  require "hbacker"
  require "hbacker/stargate"
  require "pp"
  
  class TableInfo < RightAws::ActiveSdb::Base
    columns do
      name
      start_time  :Integer
      end_time  :Integer
      max_versions :Integer
      versions :Integer
      compression
      in_memory :Boolean
      block_cache :Boolean
      blockcache :Boolean
      blocksize :Integer
      length :Integer
      ttl :Integer
      bloomfilter
      backup_name
      created_at :DateTime, :default => lambda{ Time.now }
      updated_at :DateTime
    end
  end
  
  class BackupInfo < RightAws::ActiveSdb::Base
    columns do
      name
      started_at :DateTime
      ended_at :DateTime
      dest_root
      created_at :DateTime, :default => lambda{ Time.now }
      updated_at :DateTime
    end
  end
  
  class Db 
    # Initializes SimpleDB Table and connection
    # @param [String] aws_access_key_id Amazon Access Key ID
    # @param [String] aws_secret_access_key Amazon Secret Access Key
    # @param [String] hbase_name Name to refer to the HBase cluster by
    #   Usually the FQDN with dots turned to underscores
    #
    def initialize(aws_access_key_id, aws_secret_access_key, hbase_name)
      sdb_table_name = "#{hbase_name}_table_info"
      
      # This seems to be the only way to dynmaically set the domain name
      @hbase_table_info_class = Class.new(TableInfo) { set_domain_name sdb_table_name}
      
      # connect to SDB
      RightAws::ActiveSdb.establish_connection(aws_access_key_id, aws_secret_access_key, :logger => Hbacker.log)

      # Creating a domain is idempotent. Its easier to try to create than to check if it already exists
      @hbase_table_info_class.create_domain
      BackupInfo.create_domain
    end
    
    # Records HBase Table Info into SimpleDB table
    # @param [String] table_name Name of the HBase Table
    # @param [Integer] start_time Earliest Time to backup from (milliseconds since Unix Epoch)
    # @param [Integer] end_time Latest Time to backup to (milliseconds since Unix Epoch)
    # @param [Stargate::Model::TableDescriptor] table_descriptor Schema of the HBase Table
    # @param [Integer] versions Max number of row/cell versions to backup
    # @param [String] backup_name Name (usually the date_time_stamp) of the backup session
    #
    def record_table_info(table_name, start_time, end_time, table_descriptor, versions, backup_name)
      table_descriptor.column_families_to_hashes.each do |column|
        @hbase_table_info_class.create(column.merge(
          {
            :table_name => table_name, 
            :start_time => start_time, 
            :end_time => end_time, 
            :updated_at => Time.now
          }))
      end
    end
  
  # Records the begining of a backup session
  # @param [String] backup_name Name (usually the date_time_stamp) of the backup session
  # @param [Time] started_at When the backup started
  # @param [String] dest_root The scheme and root path of where the backup is put
  #
  def record_backup_start(backup_name, started_at, dest_root)
    BackupInfo.create(
      {
        :name => backup_name, 
        :started_at => started_at, 
        :dest_root => dest_root, 
        :updated_at => Time.now
      }
    )
  end
  
  # Records the end of a backup session (Updates existing record)
  # @param [String] backup_name Name (usually the date_time_stamp) of the backup session
  # @param [Time] ended_at When the backup ended
  # @param [String] dest_root The scheme and root path of where the backup is put
  #
  def record_backup_end(backup_name, dest_root, ended_at)
    info = BackupInfo.find_by_name_and_dest_root(backup_name, dest_root)
    info.reload
    info[:ended_at] = ended_at
    info[:updated_at] = Time.now
    info.save
  end
  
  # Returns a list of names of tables backed up during the specified session
  # @param [String] backup_name Name (usually the date_time_stamp) of the backup session
  # @param [String] dest_root The scheme and root path of where the backup is put
  # @return [Array<String>] List of tables backed up for that session
  def table_names_by_backup_name(backup_name, dest_root)
    results = @hbase_table_info_class.find_by_backup_name_and_dest_root(backup_name, dest_root).collect do |t|
      t[:name]
    end
  end
end