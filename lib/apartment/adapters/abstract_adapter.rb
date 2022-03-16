module Apartment
  module Adapters
    class AbstractAdapter
      include ActiveSupport::Callbacks
      define_callbacks :create, :switch

      attr_reader :current

      def initialize
        reset
      rescue Apartment::TenantNotFound
        Rails.logger.warn "Unable to connect to default tenant"
      end

      def reset
        switch!(Apartment.default_tenant)
      end

      def switch(tenant = nil)
        previous_tenant = @current
        switch!(tenant)

        yield
      ensure
        begin
          switch!(previous_tenant)
        rescue => e
          Rails.logger.error "Failed to switch back to previous tenant: #{previous_tenant}"
          Rails.logger.error e.message
          e.backtrace.each do |bt|
            Rails.logger.error bt
          end
          begin
            reset
          rescue => e
            Rails.logger.error "Unable to switch back to previous tenant, or reset to default tenant: #{Apartment.default_tenant}"
            Rails.logger.error e.message
            e.backtrace.each do |bt|
              Rails.logger.error bt
            end
          end
        end
      end

      def create(tenant)
        run_callbacks :create do
          begin
            previous_tenant = @current
            config = config_for(tenant)
            difference = current_difference_from(config)

            if difference[:host]
              connection_switch!(config, without_keys: [:database, :schema_search_path])
            end

            create_tenant!(config)
            simple_switch(config)
            @current = tenant

            import_database_schema
            seed_data if Apartment.seed_after_create

            yield if block_given?
          ensure
            switch!(previous_tenant) rescue reset
          end
        end
      end

      def drop(tenant)
        previous_tenant = @current

        config = config_for(tenant)
        difference = current_difference_from(config)

        if difference[:host]
          connection_switch!(config, without_keys: [:database])
        end

        unless database_exists?(config[:database])
          raise TenantNotFound, "Error while dropping database #{config[:database]} for tenant #{tenant}"
        end

        Apartment.connection.drop_database(config[:database])

        @current = tenant
      ensure
        switch!(previous_tenant) rescue reset
      end

      def switch!(tenant)
        run_callbacks :switch do
          unless valid_tenant?(tenant)
            raise_connect_error!(tenant, ApartmentError.new("Invalid tenant!"))
          end

          config = config_for(tenant)

          if Apartment.force_reconnect_on_switch
            connection_switch!(config)
          else
            switch_tenant(config)
          end

          Apartment.connection.clear_query_cache

          @current = tenant
        end
      end

      def config_for(tenant)
        return tenant if tenant.is_a?(Hash)

        decorated_tenant = decorate(tenant)
        Apartment.tenant_resolver.resolve(decorated_tenant)
      end

      def decorate(tenant)
        decorator = Apartment.tenant_decorator
        decorator ? decorator.call(tenant) : tenant
      end

      def process_excluded_models
        excluded_config = config_for(Apartment.default_tenant)
        Apartment.connection_handler.establish_connection(excluded_config, owner_name: "_apartment_excluded")

        Apartment.excluded_models.each do |excluded_model|
          # user mustn't have overridden `connection_specification_name`
          # cattr_accessor in model
          excluded_model.constantize.connection_specification_name = "_apartment_excluded"
        end
      end

      def setup_connection_specification_name
        Apartment.connection_class.connection_specification_name = nil
        Apartment.connection_class.instance_eval do
          def connection_specification_name
            if !defined?(@connection_specification_name) || @connection_specification_name.nil?
              apartment_spec_name = Thread.current[:_apartment_connection_specification_name]
              return apartment_spec_name ||
                (self == ActiveRecord::Base ? "ActiveRecord::Base" : superclass.connection_specification_name)
            end
            @connection_specification_name
          end
        end
      end

      def current_difference_from(config)
        current_config = config_for(@current)
        config.select{ |k, v| current_config[k] != v }
      end

      def connection_switch!(config, without_keys: [], reconnect: false)
        config = config.reject{ |k, _| without_keys.include?(k) }
        owner_name = connection_specification_name(config)

        Apartment.connection_handler.remove_connection(owner_name) if reconnect

        unless Apartment.connection_handler.retrieve_connection_pool(owner_name)
          Apartment.connection_handler.establish_connection(config, owner_name: owner_name)
        end

        begin
          previous = Thread.current[:_apartment_connection_specification_name]
          Thread.current[:_apartment_connection_specification_name] = owner_name

          if (config[:database] || config[:schema_search_path]) && !reconnect
            simple_switch(config)
          end
        rescue
          Thread.current[:_apartment_connection_specification_name] = previous

          raise
        end
      end

      def import_database_schema
        ActiveRecord::Schema.verbose = false

        load_or_abort(Apartment.database_schema_file) if Apartment.database_schema_file
      end

      def seed_data
        silence_warnings{ load_or_abort(Apartment.seed_data_file) } if Apartment.seed_data_file
      end

      def load_or_abort(file)
        if File.exist?(file)
          load(file)
        else
          abort %{#{file} doesn't exist yet}
        end
      end

      def raise_connect_error!(tenant, exception)
        raise TenantNotFound, "Error while connecting to tenant #{tenant}: #{exception.message}"
      end
    end
  end
end
