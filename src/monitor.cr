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
        puts "\n\033[1;31m=== ALERTS ===\033[0m\n"
        display_table(alerts, red: true)
      end

      if ok.any?
        puts "\n\033[1;32m=== OK ===\033[0m\n"
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
        results.concat(check_filesystem(name, fs_check))
      end
      return results
    end # perform_checks

    private def check_filesystem(name : String, fs_check : FilesystemCheck) : Array(Check)
      results = [] of Check

      usage = get_filesystem_usage(fs_check.path)
      return results unless usage

      if threshold = fs_check.usage
        used_bytes = usage[:used].as(Int64)
        total_bytes = usage[:total].as(Int64)
        usage_pct = usage[:usage_pct].as(Float64)

        case threshold.unit
        when :bytes
          limit_bytes = threshold.to_bytes
          status = used_bytes > limit_bytes ? :alert : :ok
          msg = status == :alert ? "Filesystem usage exceeds limit" : "Within limits"
          results << Check.new(
            "Filesystem #{name}",
            status,
            format_bytes(used_bytes),
            threshold.format_value,
            msg
          )
        when :percent
          limit_pct = threshold.to_percent
          status = usage_pct > limit_pct ? :alert : :ok
          msg = status == :alert ? "Filesystem usage exceeds limit" : "Within limits"
          results << Check.new(
            "Filesystem #{name}",
            status,
            "%.2f%%" % usage_pct,
            "%.2f%%" % limit_pct,
            msg
          )
        end
      end

      results
    end

    private def get_filesystem_usage(path : String) : Hash(Symbol, Int64 | Float64)?
      output = `df -B1 #{path} 2>/dev/null`.lines
      return nil if output.size < 2

      parts = output[1].split
      total = parts[1].to_i64
      used = parts[2].to_i64

      result = Hash(Symbol, Int64 | Float64).new
      result[:total] = total
      result[:used] = used
      result[:available] = parts[3].to_i64
      result[:usage_pct] = (used.to_f64 / total.to_f64) * 100.0
      result
    rescue
      nil
    end

    private def format_bytes(bytes : Int64) : String
      units = ["B", "KB", "MB", "GB", "TB", "PB"]
      size = bytes.to_f64
      unit_idx = 0

      while size >= 1024.0 && unit_idx < units.size - 1
        size /= 1024.0
        unit_idx += 1
      end

      "%.2f %s" % [size, units[unit_idx]]
    end
  end # SystemMonitor
end # Jane
