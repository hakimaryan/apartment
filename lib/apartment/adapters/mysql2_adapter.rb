require 'apartment/adapters/abstract_adapter'

module Apartment
  module Adapters
    # Mysql2 Adapter - simplified approach based on ros-apartment
    class Mysql2Adapter < AbstractAdapter
      def initialize
        super
      end

      def create_tenant!(tenant)
        database_name = if tenant.is_a?(Hash)
          tenant[:database]
        else
          environmentify(tenant)
        end

        Apartment.connection.create_database(database_name)
      rescue ActiveRecord::StatementInvalid => e
        raise_connect_error!(tenant, e)
      end

      protected

      def rescue_from
        Mysql2::Error
      end

      # Simple connection method - just use USE database like ros-apartment
      def connect_to_new(tenant)
        return reset if tenant.nil?

        # Handle both string tenant names and hash configs
        database_name = if tenant.is_a?(Hash)
          tenant[:database]
        else
          environmentify(tenant)
        end

        Apartment.connection.execute "use `#{database_name}`"
        @current = tenant
      rescue ActiveRecord::StatementInvalid => e
        raise_connect_error!(tenant, e)
      end

      def reset
        return unless default_tenant

        # Handle both string tenant names and hash configs
        database_name = if default_tenant.is_a?(Hash)
          default_tenant[:database]
        else
          environmentify(default_tenant)
        end

        Apartment.connection.execute "use `#{database_name}`"
        @current = default_tenant
      rescue ActiveRecord::StatementInvalid => e
        # During initial setup (like CI), the default database might not exist yet
        # Raise the proper exception that the abstract adapter's initialize method expects
        raise Apartment::TenantNotFound, "Could not reset to default tenant #{database_name}: #{e.message}"
      end

      def default_tenant
        @default_tenant || Apartment.default_tenant
      end

      def reset_on_connection_exception?
        true
      end
    end
  end
end
