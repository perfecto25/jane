require "../system_info"
require "../config"

#module Jane
#  module Cpu
    def check_cpu(cpu_check : CPUCheck) : Array(Check)
      results = [] of Check

      # CPU Usage
      if threshold = cpu_check.usage
        usage = SystemInfo.calculate_cpu_usage

        case threshold.unit
        when :percent
          limit = threshold.to_percent
          status = usage > limit ? :alert : :ok
          msg = status == :alert ? "CPU usage exceeds limit" : "Within limits"
          results << Check.new(
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
          results << Check.new(
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
            results << Check.new(
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
    end
    #  end # Cpu
    #end  # Jane
