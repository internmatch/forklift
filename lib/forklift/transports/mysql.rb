require 'mysql2'

module Forklift
  module Connection
    class Mysql < Forklift::Base::Connection

      def initialize(config, forklift)
        @config = config
        @forklift = forklift
        @client = Mysql2::Client.new(config)
        # q("USE #{config['database']}")
      end

      def config
        @config
      end

      def forklift
        @forklift
      end

      def default_matcher
        'updated_at'
      end

      def drop!(table, database=current_database)
        q("DROP table `#{database}`.`#{table}`");
      end

      def read(query, database=current_database, looping=true, limit=1000, offset=0)
        loop_count = 0
        # TODO: Detect limit/offset already present in query
        q("USE `#{database}`")

        while ( looping == true || loop_count == 0 )
          data = []
          prepared_query = query
          if prepared_query.downcase.include?("select") && !prepared_query.downcase.include?("limit")
            prepared_query = "#{prepared_query} LIMIT #{offset}, #{limit}"
          end
          response = q(prepared_query, :symbolize_keys => true)
          response.each do |row|
            data << row
          end

          if block_given?
            yield data
          else
            return data
          end

          offset = offset + limit
          looping = false if data.length == 0
          loop_count = loop_count + 1
        end
      end

      def write(data, table, to_update=true, database=current_database, primary_key='id', lazy=true, crash_on_extral_col=false)
        data.map{|l| forklift.utils.symbolize_keys(l) }

        if tables.include? table
          # all good, cary on
        elsif(lazy == true && data.length > 0)
          lazy_table_create(table, data, database, primary_key)
        end

        if data.length > 0
          columns = columns(table, database)
          data.each do |d|
            d = clean_to_columns(d, columns) unless crash_on_extral_col == true
            if(to_update == true && !d[primary_key.to_sym].nil?)
              q("DELETE FROM `#{database}`.`#{table}` WHERE `#{primary_key}` = #{d[primary_key.to_sym]}")
            end
            q("INSERT INTO `#{database}`.`#{table}` (#{safe_columns(d.keys)}) VALUES (#{safe_values(d.values)});")
          end
          forklift.logger.log "wrote #{data.length} rows to `#{database}`.`#{table}`"
        end
      end

      def lazy_table_create(table, data, database=current_database, primary_key='id')
        keys = {}
        data.each do |item|
          item.each do |k,v|
            keys[k] = sql_type(v) if keys[k].nil?
          end
        end

        command = "CREATE TABLE `#{database}`.`#{table}` ( "
        command << " `#{primary_key}` int(11) NOT NULL AUTO_INCREMENT, " if ( data.first[primary_key.to_sym].nil? )
        keys.each do |col, type|
          command << " `#{col}` #{type} DEFAULT NULL, "
        end
        command << " PRIMARY KEY (`#{primary_key}`) "
        command << " ) "

        q(command)
        forklift.logger.log "lazy-created table `#{database}`.`#{table}`"
      end

      def sql_type(v)
        return "int(11)"      if v.class == Fixnum
        return "float"        if v.class == Float
        return "date"         if v.class == Date
        return "datetime"     if v.class == Time
        return "datetime"     if v.class == DateTime
        return "varchar(255)" if v.class == Symbol
        return "tinyint(1)"   if v.class == TrueClass
        return "tinyint(1)"   if v.class == FalseClass
        return "text"         if v.class == String
        return "text"         if v.class == NilClass
        return "text"         # catchall
      end

      def pipe(from_db, from_table, to_db, to_table)
        start = Time.new.to_i
        forklift.logger.log("mysql pipe: `#{from_db}`.`#{from_table}` => `#{to_db}`.`#{to_table}`")
        q("drop table if exists `#{to_db}`.`#{to_table}`")
        q("create table `#{to_db}`.`#{to_table}` like `#{from_db}`.`#{from_table}`")
        q("insert into `#{to_db}`.`#{to_table}` select * from `#{from_db}`.`#{from_table}`")
        delta = Time.new.to_i - start
        forklift.logger.log("  ^ moved #{count(to_table, to_db)} rows in #{delta}s")
      end

      def incremental_pipe(from_db, from_table, to_db, to_table, matcher=default_matcher, primary_key='id')
        start = Time.new.to_i
        forklift.logger.log("mysql incremental_pipe: `#{from_db}`.`#{from_table}` => `#{to_db}`.`#{to_table}`")
        q("create table if not exists `#{to_db}`.`#{to_table}` like `#{from_db}`.`#{from_table}`")

        # Count the number of rows in to_table
        original_count = count(to_table, to_db)

        # Find the latest/max/newest timestamp from the final table
        # in order to determine the last copied row.
        latest_timestamp = max_timestamp(to_table, matcher, to_db)

        # If to_table has existing rows, ensure none of them are "stale."
        # A stale row in to_table means a previously copied row was
        # updated in from_table, so let's delete it from the to_table
        # so we can get a fresh copy of that row.
        if original_count > 0
          # Get the ids of rows in from_table that are newer than the newest row in to_table.
          # Some of these rows could either be a) stale or b) new.
          read("select `#{primary_key}` from `#{from_db}`.`#{from_table}` where `#{matcher}` > \"#{latest_timestamp}\" order by `#{matcher}`") do |stale_rows|
            if stale_rows.length > 0
              # Delete these ids from to_table.
              # If the ids are stale, then they'll be deleted. If they're new, they won't exist, and nothing will happen.
              stale_ids = stale_rows.map { |row| row[primary_key.to_sym] }.join(',')
              q("delete from `#{to_db}`.`#{to_table}` where `#{primary_key}` in (#{stale_ids})")
              forklift.logger.log("  ^ deleted up to #{stale_rows.length} stale rows from `#{to_db}`.`#{to_table}`")
            end
          end
        end

        # Do the insert into to_table
        q("insert into `#{to_db}`.`#{to_table}` select * from `#{from_db}`.`#{from_table}` where `#{matcher}` > \"#{latest_timestamp}\" order by `#{matcher}`")
        delta = Time.new.to_i - start
        new_count = count(to_table, to_db) - original_count
        forklift.logger.log("  ^ created #{new_count} new rows in #{delta}s")
      end

      def optimistic_pipe(from_db, from_table, to_db, to_table, matcher=default_matcher, primary_key='id')
        if can_incremental_pipe?(from_db, from_table)
          incremental_pipe(from_db, from_table, to_db, to_table, matcher, primary_key)
        else
          pipe(from_db, from_table, to_db, to_table)
        end
      end

      def can_incremental_pipe?(from_db, from_table, matcher=default_matcher)
        columns(from_table, from_db).include?(matcher)
      end

      def read_since(table, since, matcher=default_matcher, database=current_database)
        query = "select * from `#{database}`.`#{table}` where `#{matcher}` >= '#{since}' order by `#{matcher}` asc"
        self.read(query, database){|data|
          if block_given?
            yield data
          else
            return data
          end
        }
      end

      def max_timestamp(table, matcher=default_matcher, database=current_database)
        last_copied_row = read("select max(`#{matcher}`) as \"#{matcher}\" from `#{database}`.`#{table}`")[0]
        if ( last_copied_row.nil? || last_copied_row[matcher.to_sym].nil? )
          latest_timestamp = '1970-01-01 00:00'
        else
          return last_copied_row[matcher.to_sym].to_s
        end
      end

      def tables
        t = []
        client.query("show tables").each do |row|
          t << row.values[0]
        end
        t
      end

      def current_database
        q("select database() as 'db'").first['db']
      end

      def count(table, database=current_database)
        read("select count(1) as \"count\" from `#{database}`.`#{table}`")[0][:count]
      end

      def truncate!(table, database=current_database)
        q("truncate table `#{database}`.`#{table}`")
      end

      def truncate(table, database=current_database)
        begin
          self.truncate!(table, database=current_database)
        rescue Exception => e
          forklift.logger.debug e
        end
      end

      def columns(table, database=current_database)
        cols = []
        read("describe `#{database}`.`#{table}`").each do |row|
          cols << row[:Field]
        end
        cols
      end

      def dump(file)
        cmd = "mysqldump"
        cmd << " -u#{config['username']}" unless config['username'].nil?
        cmd << " -p#{config['password']}" unless config['password'].nil?
        cmd << " --max_allowed_packet=512M"
        cmd << " #{config['database']}"
        cmd << " | gzip > #{file}"
        forklift.logger.log "Dumping #{config['database']} to #{file}"
        forklift.logger.debug cmd
        `#{cmd}`
        forklift.logger.log "  > Dump complete"
      end

      def exec_script(path)
        body = File.read(path)
        lines = body.split(';')
        lines.each do |line|
          line.strip!
          q(line) if line.length > 0
        end
      end

      def q(query, options={})
        forklift.logger.debug "    SQL: #{query}"
        return client.query(query, options)
      end

      private

      def safe_columns(cols)
        a = []
        cols.each do |c|
          a << "`#{c}`"
        end
        return a.join(', ')
      end

      def clean_to_columns(row, columns)
        r = {}
        row.each do |k,v|
          r[k] = row[k] if columns.include?(k.to_s)
        end
        r
      end

      def safe_values(values)
        a = []
        values.each do |v|
          part = "NULL"
          if( [::String, ::Symbol].include?(v.class) )
            v.gsub!('\"', '\/"')
            v.gsub!('"', '\"')
            part = "\"#{v}\""
          elsif( [::Date, ::Time].include?(v.class) )
            s = v.to_s(:db)
            part = "\"#{s}\""
          elsif( [::Fixnum].include?(v.class) )
            part = v
          elsif( [::Float].include?(v.class) )
            part = v.to_f
          end
          a << part
        end
        return a.join(', ')
      end

      #/private

    end
  end
end
