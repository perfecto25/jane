require "../info"
require "../monitor"
require "../config"

## all metrics, checks and anything related to CPU, Loadavg, IO Wait

module Jane
  module Cpu
    extend self

    # ------------ INFO

    private def read_iowait : Float64
      stat1 = read_cpu_stat
      sleep 100.milliseconds
      stat2 = read_cpu_stat
      total_diff = stat2[:total] - stat1[:total]
      iowait_diff = stat2[:iowait] - stat1[:iowait]
      return 0.0 if total_diff == 0
      (iowait_diff.to_f64 / total_diff.to_f64) * 100.0
    end

    private def read_cpu_stat : Hash(Symbol, Int64)
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
      result[:idle] = idle + iowait
      result[:iowait] = iowait
      result[:total] = user + nice + system + idle + iowait + irq + softirq
      return result
    end

    ## used by Info
    def read_cpu_info : Hash(Symbol, String | Int32)
      model = ""
      cores = 0
      File.each_line("/proc/cpuinfo") do |line|
        if line.starts_with?("model name")
          model = line.split(":", 2)[1].strip if model.empty?
        elsif line.starts_with?("processor")
          cores += 1
        end
      end
      result = Hash(Symbol, String | Int32).new
      result[:model] = model
      result[:cores] = cores
      return result
    end

    ## used by Info
    def calculate_cpu_usage : Float64
      stat1 = read_cpu_stat
      sleep 100.milliseconds
      stat2 = read_cpu_stat
      total_diff = stat2[:total] - stat1[:total]
      idle_diff = stat2[:idle] - stat1[:idle]
      return 0.0 if total_diff == 0
      ((total_diff - idle_diff).to_f64 / total_diff.to_f64) * 100.0
    end

    ## used by Info
    def read_loadavg : Array(Float64)
      parts = File.read("/proc/loadavg").split
      [parts[0].to_f64, parts[1].to_f64, parts[2].to_f64]
    end


    # ---------- CHECKS
    def check_cpu(cpu_check : CPUCheck) : Array(Monitor::Check)
      # checks if active CPU usage, IO wait and Load Average is above threshold
      results = [] of Monitor::Check

      # CPU Usage
      if threshold = cpu_check.usage
        usage = calculate_cpu_usage

        case threshold.unit
        when :percent
          limit = threshold.to_percent
          status = usage > limit ? :alert : :ok
          msg = status == :alert ? "CPU usage exceeds limit" : "Within limits"
          results << Monitor::Check.new(
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
          results << Monitor::Check.new(
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
        loadavg = read_loadavg
        ["1min", "5min", "15min"].each_with_index do |period, idx|
          if idx < limits.size
            current = loadavg[idx]
            limit = limits[idx]
            status = current > limit ? :alert : :ok
            msg = status == :alert ? "Load average exceeds limit" : "Within limits"
            results << Monitor::Check.new(
              "Load Avg (#{period})",
              status,
              "%.2f" % current,
              "%.2f" % limit,
              msg
            )
          end
        end
      end
      return results
    end # check_cpu



  end # Cpu
end  # Jane
