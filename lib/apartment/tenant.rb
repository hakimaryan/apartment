require 'forwardable'

module Apartment
  #   The main entry point to Apartment functions
  #
  module Tenant

    extend self
    extend Forwardable

    def_delegators :adapter, :create, :drop, :drop_schema, :switch, :switch!,
      :current, :each, :reset, :set_callback, :seed, :current_tenant,
      :default_tenant, :config_for

    #   Initialize Apartment config options such as excluded_models
    #
    def init
      adapter.setup_connection_specification_name
      adapter.process_excluded_models
    end

    #   Fetch the proper multi-tenant adapter based on Rails config
    #
    #   @return {subclass of Apartment::AbstractAdapter}
    #
    def adapter
      # Use Fiber-local storage for Rails 7.2+ compatibility to avoid deadlocks
      storage_key = :apartment_adapter

      if rails_7_2_or_later?
        Fiber[storage_key] ||= create_adapter_instance
      else
        Thread.current[storage_key] ||= create_adapter_instance
      end
    end

    def reload!
      storage_key = :apartment_adapter

      if rails_7_2_or_later?
        Fiber[storage_key] = nil
      else
        Thread.current[storage_key] = nil
      end
    end

    private

    def rails_7_2_or_later?
      defined?(Rails) && Rails.version >= "7.2"
    end

    def create_adapter_instance
      config = Apartment.default_tenant
      adapter_name = "#{config[:adapter]}_adapter"

      begin
        require "apartment/adapters/#{adapter_name}"
        adapter_class = Adapters.const_get(adapter_name.classify)
      rescue LoadError, NameError
        raise AdapterNotFound, "The adapter `#{adapter_name}` is not yet supported"
      end

      adapter_class.new.tap do |adapter|
        adapter.setup_connection_specification_name
        adapter.process_excluded_models
      end
    end
  end
end
