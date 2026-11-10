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
      # checks if active CPU usage, IO wait and Load Average is above threshold.
      # Each threshold level produces its own row.
      results = [] of Monitor::Check

      percent = cpu_check.usage.select { |t| t.unit == :percent }
      unless percent.empty?
        usage = calculate_cpu_usage
        percent.each do |threshold|
          limit = threshold.to_percent
          status = usage > limit ? :alert : :ok
          results << Monitor.level_check("CPU Usage", threshold, percent,
          status, "%.2f%%" % usage, "%.2f%%" % limit,
          status == :alert ? "CPU usage exceeds limit" : "Within limits")
        end
      end

      percent = cpu_check.iowait.select { |t| t.unit == :percent }
      unless percent.empty?
        iowait = read_iowait
        percent.each do |threshold|
          limit = threshold.to_percent
          status = iowait > limit ? :alert : :ok
          results << Monitor.level_check("CPU IO Wait", threshold, percent,
          status, "%.2f%%" % iowait, "%.2f%%" % limit,
          status == :alert ? "IO wait exceeds limit" : "Within limits")
        end
      end

      unless cpu_check.loadavg.all?(&.empty?) && cpu_check.loadavg_per_core.all?(&.empty?)
        loadavg = read_loadavg
        cores = online_cpus
        LOADAVG_PERIODS.each_with_index do |period, idx|
          results.concat loadavg_results("Load Avg (#{period})", loadavg[idx], cpu_check.loadavg[idx]?, nil)
          results.concat loadavg_results("Load Avg (#{period}) per core", loadavg[idx] / cores, cpu_check.loadavg_per_core[idx]?, cores)
        end
      end
      return results
    end # check_cpu

    LOADAVG_PERIODS = ["1min", "5min", "15min"]

    private def loadavg_results(name : String, current : Float64, levels : Array(Threshold)?,
                                cores : Int32?) : Array(Monitor::Check)
      return [] of Monitor::Check unless levels
      levels.map do |threshold|
        status = current > threshold.value ? :alert : :ok
        message = if status == :ok
                    "Within limits"
                  elsif cores
                    "Load average per core exceeds limit (#{cores} CPUs)"
                  else
                    "Load average exceeds limit"
                  end
        Monitor.level_check(name, threshold, levels,
          status, "%.2f" % current, "%.2f" % threshold.value,
          message)
      end
    end

    # CPUs the scheduler can use (what the load average is spread over).
    def online_cpus : Int32
      Math.max(System.cpu_count.to_i32, 1)
    end



  end # Cpu
end  # Jane
