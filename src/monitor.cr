require "tallboy"
require "json"
require "./info"
require "./utils/*"

module Jane
  module Monitor
    extend self

    struct Check
      include JSON::Serializable
      property name : String
      property status : Symbol
      property current : String
      property limit : String
      property message : String

      def initialize(@name, @status, @current, @limit, @message)
      end

    end

    def display_status(config : Config)
      results = perform_checks(config)

      alerts = results.select { |r| r.status == :alert }
      ok = results.select { |r| r.status == :ok }

      if alerts.any?
        puts "\n\033[1;31m[ ALERTS ]\033[0m\n"
        display_table(alerts, red: true)
      end

      if ok.any?
        puts "\n\033[1;32m[ OK ]\033[0m\n"
        display_table(ok)
      end

      puts "\nTotal Checks: #{results.size} | Alerts: #{alerts.size} | OK: #{ok.size}"
    end

    private def display_table(results : Array(Check), red : Bool = false)
      table = Tallboy.table do
        header ["Check", "Status", "Current", "Limit", "Message"]

        results.each do |r|
          status_symbol = r.status == :alert ? "✗" : "✓"
          row [r.name, status_symbol, r.current, r.limit, r.message]
        end
      end

      output = table.render
      puts red ? "\033[31m#{output}\033[0m" : output
    end


    def perform_checks(config : Config) : Array(Check)
      results = [] of Check

      # CPU checks
      if cpu = config.check.cpu
        results.concat(Cpu.check_cpu(cpu))
      end

      # Memory checks
      if memory = config.check.memory
        results.concat(Memory.check_memory(memory))
      end

      # Filesystem checks
      config.check.filesystems.each do |name, fs_check|
        puts name
        results.concat(Filesystem.check_filesystem(name, fs_check))
      end

      #  checks
      config.check.network.interface.each do |name, iface_check|
        puts name
        results.concat(Network.check_iface(name, iface_check))
      end


      return results
    end # perform_checks


  end # SystemMonitor
end # Jane
