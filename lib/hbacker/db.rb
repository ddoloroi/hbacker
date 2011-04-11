module Hbacker
  require "right_aws"
  require "sdb/active_sdb"
  require "hbacker"

  class Db
    attr_reader :aws_access_key_id, :aws_secret_access_key, :hbase_name
    # Initializes SimpleDB Table and connection
    # @param [String] aws_access_key_id Amazon Access Key ID
    # @param [String] aws_secret_access_key Amazon Secret Access Key
    # @param [String] hbase_name Name to refer to the HBase cluster by
    #   Usually the FQDN with dots turned to underscores
    #
    def initialize(mode, aws_access_key_id, aws_secret_access_key, hbase_name, reiteration_time=5)
      raise DbError, "Invalid mode: #{mode.inspect}" unless [:import, :export].include?(mode)
      @mode = mode
      @aws_access_key_id = aws_access_key_id
      @aws_secret_access_key =aws_secret_access_key
      @hbase_name = hbase_name
      @db_count ||= 0
      @db_count += 1
      
      if @mode == :export
        create_export_table_classes(@hbase_name)
      else
        create_import_table_classes(@hbase_name)
      end
      
      # connect to SDB
      RightAws::ActiveSdb.establish_connection(aws_access_key_id, aws_secret_access_key, :logger => Hbacker.log)

      orig_reiteration_time = RightAws::AWSErrorHandler::reiteration_time
      RightAws::AWSErrorHandler::reiteration_time = reiteration_time

      # Creating a domain is idempotent. Its easier to try to create than to check if it already exists
      if @mode == :export
        ExportSession.create_domain
        ExportedHbaseTable.create_domain
        ExportedColumnDescriptor.create_domain
      else
        ImportSession.create_domain
        ImportedHbaseTable.create_domain
        ImportedColumnDescriptor.create_domain
      end
    end
    
    class DbError < HbackerError ; end
    
    # Records Exported HBase Table Info into SimpleDB table
    # @param [String] table_name Name of the HBase Table
    # @param [Integer] start_time Earliest Time to export from (milliseconds since Unix Epoch)
    # @param [Integer] end_time Latest Time to export to (milliseconds since Unix Epoch)
    # @param [Stargate::Model::TableDescriptor] table_descriptor Schema of the HBase Table
    # @param [Integer] versions Max number of row/cell versions to export
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [Boolean] empty True if the table is totally empty
    # @param [Boolean] error True if there was a hard error while doing the operation
    # @param [String] error_info Basic info about the error if error is true
    #
    def exported_table_info(table_name, start_time, end_time, table_descriptor, versions, session_name, empty=false, error={})
      now = Time.now.utc
      table_info = {
        :table_name => table_name,
        :start_time => start_time,
        :end_time => end_time,
        :session_name => session_name,
        :empty => empty,
        :error => error.empty? ? false : true,
        :error_info => error.empty? ? nil : error[:info],
        :specified_versions => versions,
        :updated_at => now
      }
      ExportedHbaseTable.create(table_info)
      
      if table_descriptor
        table_descriptor.column_families_to_hashes.each do |column|
          column.merge!(
          {
            :table_name => table_name, 
            :session_name => session_name,
            :updated_at => now
          }
          )
          ExportedColumnDescriptor.create(column)
        end
      end
    end
  
    # Records Imported HBase Table Info into SimpleDB table
    # @param [String] table_name Name of the HBase Table
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [Boolean] empty True if the table is totally empty
    # @param [Boolean] error True if there was a hard error while doing the operation
    # @param [String] error_info Basic info about the error if error is true
    #
    def imported_table_info(table_name, session_name, empty=false, error={})
      now = Time.now.utc
      table_info = {
        :table_name => table_name,
        :session_name => session_name,
        :empty => empty,
        :error => error.empty? ? false : true,
        :error_info => error.empty? ? nil : error[:info],
        :updated_at => now
      }
      
      ImportedHbaseTable.create(table_info)
      
      if table_descriptor
        table_descriptor.column_families_to_hashes.each do |column|
          column.merge!(
          {
            :table_name => table_name, 
            :session_name => session_name,
            :updated_at => now
          }
          )
          ImportedColumnDescriptor.create(column)
        end
      end
    end
  
    # Records the begining of a export session
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [String] dest_root The scheme and root path of where the export is put
    # @param [Integer] specified_start The start_time of the earliest record to be backed up.
    #   Value of 0 means its a full export
    # @param [Integer] specified_end End time of the last record to be backed up
    # @param [Time] started_at When the export started
    #
    def start_info(session_name, dest_root, specified_start, specified_end, started_at)
      session_info = {
        :session_name => session_name, 
        :specified_start => specified_start,
        :specified_end => specified_end,
        :started_at => started_at, 
        :dest_root => dest_root, 
        :cluster_name => @hbase_name,
        :updated_at => Time.now.utc
      }
      
      case @mode
      when :export
        klass = ExportSession
      when :import
        klass = ImportSession
      end
      klass.create(session_info)
    end
  
    # Records the end of a export session (Updates existing record)
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [Time] ended_at When the export ended
    # @param [String] dest_root The scheme and root path of where the export is put
    #
    def end_info(session_name, dest_root, ended_at, error={})
      now = Time.now.utc
      case @mode
      when :export
        klass = ExportSession
      when :import
        klass = ImportSession
      end
      
      # Loop prevents a race condition of the start_info call update not being complete before the end_info call
      count = 0
      info = nil
      while (info = klass.find_by_cluster_name_and_session_name_and_dest_root(@hbase_name, session_name, dest_root)).nil? && count < 10
        sleep 3
        count += 1
      end
      raise DbError, "#{klass.class}.find_by_cluster_name_and_session_name_and_dest_root(#{@hbase_name}, #{session_name}, #{dest_root}) is nil" if info.nil?
      
      info.reload
      info.save_attributes(
      :error => error.empty? ? false : true,
      :error_info => error.empty? ? nil : error[:info],
      :ended_at => ended_at,
      :updated_at => now
      )
    end
  
    # Returns a list of names of tables backed up during the specified session
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [String] dest_root The scheme and root path of where the export is put
    # @return [Array<String>] List of table namess that were backed up for specified session
    #
    def table_names(session_name, dest_root, table_name=nil)
      if table_name && table_name.include?("%")
        conditions = ['table_name like ? AND session_name = ? AND dest_root = ?', table_name, session_name, dest_root]
      else
        conditions = ['session_name = ? AND dest_root = ?', session_name, dest_root]
      end
      
      case @mode
      when :export
        klass = ExportedHbaseTable
      when :import
        klass = ImportedHbaseTable
      end

      results = klass.select(:all, :conditions => conditions).collect do |t|
        t.reload
        t[:table_name]
      end
    end
    
    # Returns a list of info for tables backed up during the specified session
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    # @param [String] dest_root The scheme and root path of where the export is put
    # @param [String] table_name If specified, only the table name selected will be returnd.
    #   % can be used as a wildcard at begining and/or end
    # @return [Array<Hash>] List of table info that were backed up for specified session
    #
    def list_table_info(session_name, dest_root, table_name=nil)
      if table_name && table_name.include?("%")
        conditions = ['table_name like ? AND session_name = ? AND dest_root = ?', table_name, session_name, dest_root]
      else
        conditions = ['session_name = ? AND dest_root = ?', session_name, dest_root]
      end
      
      case @mode
      when :export
        klass = ExportedHbaseTable
      when :import
        klass = ImportedHbaseTable
      end
      
      results = klass.select(:all, :conditions => conditions).collect do |t|
        t.reload
        t.attributes
      end
    end
    
    ##
    # Get the Attributes of an HBase table previously recorded ColumnDescriptor Opts
    # @param [String] table_name The name of the HBase table 
    # @param (see #table_names)
    # @return [Hash] The hash of attributes found
    #
    def column_descriptors(table_name, session_name)
      results = {}
      case @mode
      when :export
        klass = ExportedColumnDescriptor
      when :import
        klass = ImportedColumnDescriptor
      end

      klass.find_all_by_session_name_and_table_name(session_name, table_name).each do |t|
        t.reload
        t.each_pair do |k,v|
          results.merge(k.to_sym => v) if Stargate::Model::ColumnDescriptor.AVAILABLE_OPTS[k]
        end
      end
      results
    end

    # Returns a list of info for exports for the specified session
    # @param [String] session_name Name (usually the date_time_stamp) of the export session
    #   % can be used as a wildcard at begining and/or end
    # @return [Array<Hash>] List of export info that were backed up for specified session
    #
    def session_info(session_name)
      if session_name && session_name.include?("%")
        conditions = {:conditions  => ["session_name like ?", session_name]}
      elsif session_name
        conditions = {:conditions  => ["session_name = ?", session_name]}
      else
        conditions = nil
      end

      case @mode
      when :export
        klass = ExportSession
      when :import
        klass = ImportSession
      end
      
      klass.select(:all, conditions).collect do |session_info|
        session_info.reload
        session_info.attributes
      end
    end
    
    # private
    def create_export_table_classes(hbase_name)
      # Dynmaically create Export related Class so we can dynamically set the name of the "Domain" in SimpleDB
      
        # Top level record of a export session
        # One SimpleDB table for all Exports 
        # (cluster_name specifies the HBase Cluster backed up)
        # One record per export session
        Object::const_set('ExportSession',  Class.new(RightAws::ActiveSdb::Base) do
          set_domain_name "export_info"
          columns do
            cluster_name
            session_name
            dest_root
            specified_start :Integer
            specified_end :Integer
            started_at :DateTime
            ended_at :DateTime, :default  => lambda { Time.at(0) } # Can't have a nil date in ActiveSdb
            error :Boolean
            error_info
            updated_at :DateTime
            created_at :DateTime, :default => lambda{ Time.now.utc }
          end
        end
        )

      # Records the status of each HBase Table backed up
      # There is a SimpleDb Domain for each HBase Cluster backed up
      # Each row represents the state of an Hbase Table export
      Object::const_set('ExportedHbaseTable', Class.new(RightAws::ActiveSdb::Base) do
        set_domain_name "exported_#{hbase_name}_tables"
        columns do
          table_name
          session_name
          start_time  :Integer
          end_time  :Integer
          specified_versions :Integer
          empty :Boolean
          error :Boolean
          error_info :String
          created_at :DateTime, :default => lambda{ Time.now.utc }
          updated_at :DateTime
        end
      end
      )

      # Records Column Family Descriptions for each Table backed up
      # There is a SimpleDb Domain forfor each HBase Cluster backed up
      # Each row represents a Column Family of an HBase Table
      # There can be multple rows (multiple Column Families) for each HBase Table
      Object::const_set('ExportedColumnDescriptor', Class.new(RightAws::ActiveSdb::Base) do
        set_domain_name "exported_#{hbase_name}_column_descriptors"
        columns do
          session_name
          table_name
          name
          blockcache
          blocksize :Integer
          bloomfilter
          compression
          block_cache :Boolean
          max_versions :Integer
          in_memory :Boolean
          versions :Integer
          length :Integer
          ttl :Integer
          updated_at :DateTime
          created_at :DateTime, :default => lambda{ Time.now.utc }
        end
      end
      )
    end
    
    def create_import_table_classes(hbase_name)
      # Dynmaically create Export related Class so we can dynamically set the name of the "Domain" in SimpleDB
      # Top level record of an import session
      # One SimpleDB table for all Imports 
      # (cluster_name specifies the HBase Cluster imported)
      # One record per import session
      Object::const_set('ImportSession',  Class.new(RightAws::ActiveSdb::Base) do
        set_domain_name "import_info"
        columns do
          cluster_name
          session_name
          source_root
          specified_start :Integer
          specified_end :Integer
          started_at :DateTime
          ended_at :DateTime, :default  => lambda { Time.at(0) } # Can't have a nil date in ActiveSdb
          error :Boolean
          error_info
          updated_at :DateTime
          created_at :DateTime, :default => lambda{ Time.now.utc }
        end
      end
      )

      # Records the status of each HBase Table imported
      # There is a SimpleDb Domain for each HBase Cluster imported
      # Each row represents the state of an Hbase Table import
      Object::const_set('ImportedHbaseTable', Class.new(RightAws::ActiveSdb::Base) do
        set_domain_name "imported_#{hbase_name}_tables"
        columns do
          table_name
          session_name
          empty :Boolean
          error :Boolean
          error_info :String
          created_at :DateTime, :default => lambda{ Time.now.utc }
          updated_at :DateTime
        end
      end
      )

      # Records Column Family Descriptions for each Table imported
      # There is a SimpleDb Domain forfor each HBase Cluster imported
      # Each row represents a Column Family of an HBase Table
      # There can be multple rows (multiple Column Families) for each HBase Table
      Object::const_set('ImportedColumnDescriptor', Class.new(RightAws::ActiveSdb::Base) do
        set_domain_name "imported_#{hbase_name}_column_descriptors"
        columns do
          session_name
          table_name
          name
          blockcache
          blocksize :Integer
          bloomfilter
          compression
          block_cache :Boolean
          max_versions :Integer
          in_memory :Boolean
          versions :Integer
          length :Integer
          ttl :Integer
          updated_at :DateTime
          created_at :DateTime, :default => lambda{ Time.now.utc }
        end
      end
      )
    end
  end
end