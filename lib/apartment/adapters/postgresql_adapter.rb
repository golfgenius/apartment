require 'apartment/adapters/abstract_adapter'

module Apartment
  module Tenant

    def self.postgresql_adapter(config)
      adapter = Adapters::PostgresqlAdapter
      adapter = Adapters::PostgresqlSchemaAdapter if Apartment.use_schemas
      adapter = Adapters::PostgresqlSchemaFromSqlAdapter if Apartment.use_sql && Apartment.use_schemas
      adapter.new(config)
    end
  end

  module Adapters
    # Default adapter when not using Postgresql Schemas
    class PostgresqlAdapter < AbstractAdapter

    private

      def rescue_from
        PGError
      end
    end

    # Separate Adapter for Postgresql when using schemas
    class PostgresqlSchemaAdapter < AbstractAdapter

      def initialize(config)
        super

        reset
      end

      #   Reset schema search path to the default schema_search_path
      #
      #   @return {String} default schema search path
      #
      def reset
        @current = default_tenant
        @current_schema = db_connection_config(@current)[:schema] || @current
        Apartment.connection.schema_search_path = full_search_path
      end

      def current
        @current || default_tenant
      end

    protected

      def process_excluded_model(excluded_model)
        excluded_model.constantize.tap do |klass|
          # Ensure that if a schema *was* set, we override
          table_name = klass.table_name.split('.', 2).last

          klass.table_name = "#{default_tenant}.#{table_name}"
        end
      end

      def drop_command(conn, tenant)
        conn.execute(%{DROP SCHEMA "#{tenant}" CASCADE})
      end

      #   Set schema search path to new schema
      #
      def connect_to_new(tenant = nil)
        return reset if tenant.nil?
        Apartment.establish_connection multi_tenantify(tenant, false)
        new_schema = db_connection_config(tenant)[:schema] || tenant.to_s
        # raise ActiveRecord::StatementInvalid.new("Could not find schema #{tenant}") unless Apartment.connection.schema_exists? new_schema

        @current = tenant.to_s
        @current_schema = new_schema
        Apartment.connection.schema_search_path = full_search_path

      rescue *rescuable_exceptions
        raise TenantNotFound, "One of the following schema(s) is invalid: \"#{@current_schema}\" #{full_search_path}"
      end

    private

      def create_tenant_command(conn, tenant)
        conn.execute(%{CREATE SCHEMA "#{tenant}"})
      end

      #   Generate the final search path to set including persistent_schemas
      #
      def full_search_path
        persistent_schemas.map(&:inspect).join(", ")
      end

      def persistent_schemas
        [@current_schema || @current, Apartment.persistent_schemas].flatten
      end
    end

    # Another Adapter for Postgresql when using schemas and SQL
    class PostgresqlSchemaFromSqlAdapter < PostgresqlSchemaAdapter

      PSQL_DUMP_BLACKLISTED_STATEMENTS= [
        /SET search_path/i,   # overridden later
        /SET lock_timeout/i   # new in postgresql 9.3
      ]

      def import_database_schema
        clone_pg_schema
        copy_schema_migrations
      end

    private

      # Clone default schema into new schema named after current tenant
      #
      def clone_pg_schema
        pg_schema_sql = patch_search_path(pg_dump_schema)
        Apartment.connection.execute(pg_schema_sql)
      end

      # Copy data from schema_migrations into new schema
      #
      def copy_schema_migrations
        pg_migrations_data = patch_search_path(pg_dump_schema_migrations_data)
        Apartment.connection.execute(pg_migrations_data)
      end

      #   Dump postgres default schema
      #
      #   @return {String} raw SQL contaning only postgres schema dump
      #
      def pg_dump_schema

        # Skip excluded tables? :/
        # excluded_tables =
        #   collect_table_names(Apartment.excluded_models)
        #   .map! {|t| "-T #{t}"}
        #   .join(' ')

        # `pg_dump -s -x -O -n #{default_tenant} #{excluded_tables} #{dbname}`
        with_pg_env { `pg_dump -s -x -O -n #{default_tenant} #{@config[:database]}` }
      end

      #   Dump data from schema_migrations table
      #
      #   @return {String} raw SQL contaning inserts with data from schema_migrations
      #
      def pg_dump_schema_migrations_data
        with_pg_env { `pg_dump -a --inserts -t schema_migrations -t ar_internal_metadata -n #{default_tenant} #{@config[:database]}` }
      end

      # Temporary set Postgresql related environment variables if there are in @config
      #
      def with_pg_env(&block)
        pghost, pgport, pguser, pgpassword =  ENV['PGHOST'], ENV['PGPORT'], ENV['PGUSER'], ENV['PGPASSWORD']

        ENV['PGHOST'] = @config[:host] if @config[:host]
        ENV['PGPORT'] = @config[:port].to_s if @config[:port]
        ENV['PGUSER'] = @config[:username].to_s if @config[:username]
        ENV['PGPASSWORD'] = @config[:password].to_s if @config[:password]

        block.call
      ensure
        ENV['PGHOST'], ENV['PGPORT'], ENV['PGUSER'], ENV['PGPASSWORD'] = pghost, pgport, pguser, pgpassword
      end

      #   Remove "SET search_path ..." line from SQL dump and prepend search_path set to current tenant
      #
      #   @return {String} patched raw SQL dump
      #
      def patch_search_path(sql)
        search_path = "SET search_path = \"#{current}\", #{default_tenant};"
        sql.gsub!("CREATE SCHEMA #{default_tenant};", "")
        sql
          .split("\n")
          .select {|line| check_input_against_regexps(line, PSQL_DUMP_BLACKLISTED_STATEMENTS).empty?}
          .prepend(search_path)
          .join("\n")
      end

      #   Checks if any of regexps matches against input
      #
      def check_input_against_regexps(input, regexps)
        regexps.select {|c| input.match c}
      end

      #   Collect table names from AR Models
      #
      def collect_table_names(models)
        models.map do |m|
          m.constantize.table_name
        end
      end

      # Convenience method for current database name
      #
      def dbname
        Apartment.connection_config[:database]
      end
    end
  end
end
