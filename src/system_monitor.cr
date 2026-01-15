require "tallboy"
require "./system_info"

module Jane
  module SystemMonitor
    extend self

    struct CheckResult
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

    private def display_table(results : Array(CheckResult), red : Bool = false)
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

    def perform_checks(config : Config) : Array(CheckResult)
      results = [] of CheckResult
      
      # CPU checks
      if cpu = config.check.cpu
        results.concat(check_cpu(cpu))
      end
      
      # Memory checks
      if memory = config.check.memory
        results.concat(check_memory(memory))
      end
      
      # Filesystem checks
      config.check.filesystems.each do |name, fs_check|
        results.concat(check_filesystem(name, fs_check))
      end
      
      results
    end

    private def check_cpu(cpu_check : CPUCheck) : Array(CheckResult)
      results = [] of CheckResult
      
      # CPU Usage
      if threshold = cpu_check.usage
        usage = SystemInfo.calculate_cpu_usage
        
        case threshold.unit
        when :percent
          limit = threshold.to_percent
          status = usage > limit ? :alert : :ok
          msg = status == :alert ? "CPU usage exceeds limit" : "Within limits"
          results << CheckResult.new(
            "CPU Usage",
            status,
            "%.2f%%" % usage,
            "%.2f%%" % limit,
            msg
          )
        end
      end
      
      # IO Wait
      if threshold = cpu_check.iowait
        iowait = read_iowait
        
        case threshold.unit
        when :percent
          limit = threshold.to_percent
          status = iowait > limit ? :alert : :ok
          msg = status == :alert ? "IO wait exceeds limit" : "Within limits"
          results << CheckResult.new(
            "CPU IO Wait",
            status,
            "%.2f%%" % iowait,
            "%.2f%%" % limit,
            msg
          )
        end
      end
      
      # Load Average
      if limits = cpu_check.loadavg
        loadavg = SystemInfo.read_loadavg
        ["1min", "5min", "15min"].each_with_index do |period, idx|
          if idx < limits.size
            current = loadavg[idx]
            limit = limits[idx]
            status = current > limit ? :alert : :ok
            msg = status == :alert ? "Load average exceeds limit" : "Within limits"
            results << CheckResult.new(
              "Load Avg (#{period})",
              status,
              "%.2f" % current,
              "%.2f" % limit,
              msg
            )
          end
        end
      end
      
      results
    end

    private def check_memory(mem_check : MemoryCheck) : Array(CheckResult)
      results = [] of CheckResult
      mem_info = SystemInfo.read_memory_info
      
      if threshold = mem_check.usage
        used_bytes = mem_info[:used].as(Int64)
        total_bytes = mem_info[:total].as(Int64)
        usage_pct = mem_info[:usage_pct].as(Float64)
        
        case threshold.unit
        when :bytes
          limit_bytes = threshold.to_bytes
          status = used_bytes > limit_bytes ? :alert : :ok
          msg = status == :alert ? "Memory usage exceeds limit" : "Within limits"
          results << CheckResult.new(
            "Memory Usage",
            status,
            format_bytes(used_bytes),
            threshold.format_value,
            msg
          )
        when :percent
          limit_pct = threshold.to_percent
          status = usage_pct > limit_pct ? :alert : :ok
          msg = status == :alert ? "Memory usage exceeds limit" : "Within limits"
          results << CheckResult.new(
            "Memory Usage",
            status,
            "%.2f%%" % usage_pct,
            "%.2f%%" % limit_pct,
            msg
          )
        end
      end
      
      results
    end

    private def check_filesystem(name : String, fs_check : FilesystemCheck) : Array(CheckResult)
      results = [] of CheckResult
      
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
          results << CheckResult.new(
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
          results << CheckResult.new(
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

    private def read_iowait : Float64
      stat1 = read_cpu_stat_detailed
      sleep 100.milliseconds
      stat2 = read_cpu_stat_detailed
      
      total_diff = stat2[:total] - stat1[:total]
      iowait_diff = stat2[:iowait] - stat1[:iowait]
      
      return 0.0 if total_diff == 0
      (iowait_diff.to_f64 / total_diff.to_f64) * 100.0
    end

    private def read_cpu_stat_detailed : Hash(Symbol, Int64)
      line = File.read_lines("/proc/stat").first
      parts = line.split
      
      user = parts[1].to_i64
      nice = parts[2].to_i64
      system = parts[3].to_i64
      idle = parts[4].to_i64
      iowait = parts[5].to_i64
      irq = parts[6].to_i64
      softirq = parts[7].to_i64
      
      result = Hash(Symbol, Int64).new
      result[:iowait] = iowait
      result[:total] = user + nice + system + idle + iowait + irq + softirq
      result
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
  end
end