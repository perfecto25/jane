require "tallboy"
require "colorize"
require "./utils/*"
require "./state"

## monitor.cr — core monitoring structures and orchestration

module Jane
  module Monitor

    # Represents the result of a single check
    class Check
      include JSON::Serializable

      getter name : String
      getter status : String         # "ok" or "alert"
      getter current : String        # current measured value
      getter threshold : String      # configured threshold / expected value
      getter message : String        # human-readable explanation
      getter tags : Array(String)
      getter description : String?

      def initialize(@name, status : Symbol, @current, @threshold, @message, @tags = [] of String, @description = nil)
        @status = status.to_s
      end

      def alert? : Bool
        @status == "alert"
      end

      def ok? : Bool
        @status == "ok"
      end

      def to_s : String
        icon = alert? ? "✖" : "✔"
        "[#{icon}] #{@name}: #{@message} (current: #{@current}, threshold: #{@threshold})"
      end
    end # Check

    # ------------------------------------------------------------------
    # perform_checks — iterates through all configured checks and
    # collects Monitor::Check results. Each module follows the same
    # contract:  def check_*(config) : Array(Monitor::Check)
    # ------------------------------------------------------------------
    def self.perform_checks(config : Config) : Array(Check)
      results = [] of Check
      checks = config.check

      # --- CPU ---
      if cpu_check = checks.cpu
        cpu_results = Cpu.check_cpu(cpu_check)
        cpu_results.each { |c| c.tags.concat(cpu_check.tags) }
        results.concat cpu_results
      end

      # --- Memory ---
      if mem_check = checks.memory
        mem_results = Memory.check_memory(mem_check)
        mem_results.each { |c| c.tags.concat(mem_check.tags) }
        results.concat mem_results
      end

      # --- Filesystems ---
      checks.filesystems.each do |name, fs_check|
        fs_results = Filesystem.check_filesystem(name, fs_check)
        fs_results.each { |c| c.tags.concat(fs_check.tags) }
        results.concat fs_results
      end

      # --- Network: Interfaces ---
      checks.network_interfaces.each do |name, iface_check|
        iface_results = Network::Interface.check_iface(name, iface_check)
        iface_results.each { |c| c.tags.concat(iface_check.tags) }
        results.concat iface_results
      end

      # --- Network: Connections ---
      checks.network_connections.each do |name, conn_check|
        conn_results = Network::Connection.check_connection(name, conn_check)
        conn_results.each { |c| c.tags.concat(conn_check.tags) }
        results.concat conn_results
      end

      # --- Network: Bandwidth ---
      cycle = config.defaults.cycle
      checks.network_bandwidths.each do |name, bw_check|
        bw_results = Network::Bandwidth.check_bandwidth(name, bw_check, cycle)
        bw_results.each { |c| c.tags.concat(bw_check.tags) }
        results.concat bw_results
      end

      # --- Processes ---
      checks.processes.each do |name, proc_check|
        proc_results = ProcessChecker.check_process(name, proc_check)
        proc_results.each { |c| c.tags.concat(proc_check.tags) }
        results.concat proc_results
      end

      # --- Files ---
      checks.files.each do |name, file_check|
        file_results = FileChecker.check_file(name, file_check)
        file_results.each { |c| c.tags.concat(file_check.tags) }
        results.concat file_results
      end

      results
    end # perform_checks

    # ------------------------------------------------------------------
    # display_status — runs checks and prints a table to stdout
    # ------------------------------------------------------------------
    def self.display_status(config : Config, config_path : String = "config.toml")
      results = perform_checks(config)
      unmonitored_tags = State.unmonitored_tags(config_path)

      monitored = results.reject { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }
      unmonitored = results.select { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }

      sorted = monitored.sort_by { |c| c.alert? ? 0 : 1 }

      table = Tallboy.table do
        header ["Check", "Status", "Current", "Threshold", "Message", "Tags"]
        sorted.each do |check|
          tags_str = check.tags.empty? ? "" : check.tags.join(", ")
          if check.alert?
            row [check.name, check.status, check.current, check.threshold, check.message, tags_str].map { |v| v.colorize(:red).to_s }
          else
            row [check.name, check.status, check.current, check.threshold, check.message, tags_str]
          end
        end
      end
      puts table.render

      alerts = monitored.select(&.alert?)
      if alerts.any?
        puts "\n#{"⚠  #{alerts.size} alert(s) detected".colorize(:yellow).bold}"
      else
        puts "\n✔  All checks passed"
      end

      if unmonitored.any?
        puts "\n#{"Unmonitored Services".colorize(:dark_gray)}"
        seen = Set(String).new
        unmon_table = Tallboy.table do
          header ["Check", "Tags"]
          unmonitored.each do |check|
            next if seen.includes?(check.name)
            seen.add(check.name)
            row [check.name, check.tags.join(", ")]
          end
        end
        puts unmon_table.render
      end
    end

    # Filters results to only those in alert state
    def self.alerts(results : Array(Check)) : Array(Check)
      results.select(&.alert?)
    end

  end # Monitor
end # Jane