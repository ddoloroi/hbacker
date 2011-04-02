module Hbacker
  require "hbacker"
  
  class Import
    ##
    # Initialize the Import Instance
    #
    def initialize(hbase, db, hbase_home, hbase_version, hadoop_home, s3)
      @hbase = hbase
      @db = db
      @hadoop_home = hadoop_home
      @hbase_home = hbase_home
      @hbase_version = hbase_version
      @s3 = s3
    end

    ##
    # Iterates thru the list of tables calling Import#table to do the Import to the specified dest
    # * Get the list of names based on the options from the Source directory 
    # * Create the table on the target HBase using the schema from Db
    # * Call the Hadoop process to move the file
    # @param [Hash] opts Hash from the CLI with all the options set
    # @option opts [String] :source_root Scheme://root_path of the Source directory of exports
    # @option opts [String] :session_name Name of the export session / subdirectory containing table directories
    # 
    def specified_tables(opts)
      export_table_names = @db.export_table_names(opts[:session_name], opts[:source_root])
      export_table_names.each do |table|
        source = "#{opts[:source_root]}#{opts[:session_name]}/#{table}/"
        Hbacker.log.info "Backing up #{table} to #{source}"
        Hbacker.log.debug "self.table(#{table}, #{source})"
        self.table(table, source)
      end
    end
    
    ##
    # Uses Hadoop to import specfied table from source file system to target HBase Cluster
    # @param [String] table_name The name of the table to import
    # @param [String] source scheme://source_path/session_name/ to the export data
    #
    def table(table_name, source)
      
      table_status = @hbase.create_table(table_name, table_description)
      
      cmd = "#{@hadoop_home}/bin/hadoop jar #{@hbase_home}/hbase-#{@hbase_version}.jar import " +
        "#{table_name} #{source}"
      Hbacker.log.debug "About to execute #{cmd}"
      cmd_output = `#{cmd} 2>&1`
      # Hbacker.log.debug "cmd output: #{cmd_output}"
      import_session_name = Hbacker::Cli.export_timestamp
      
      if $?.exitstatus > 0
        Hbacker.log.error"Hadoop command failed: #{cmd}"
        Hbacker.log.error cmd_output
        @s3.save_info("#{destination}hbacker_hadoop_import_error_#{import_session_name}.log", cmd_output)
        raise StandardError, "Error running Haddop Command", caller
      end
      @s3.save_info("#{destination}hbacker_hadoop_error.log", cmd_output)
    end
  end
end
