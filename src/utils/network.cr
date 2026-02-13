require "../info"
require "../monitor"
require "../config"

## all metrics, checks and anything related to Network

module Jane
  module Network


    def check_iface(iface_check : NetworkInterfaceCheck) : Array(Monitor::Check)
      # checks if memory usage is above threshold
      results = [] of Monitor::Check
      mem_info = read_memory_info

      if threshold = mem_check.usage
        used_bytes = mem_info[:used].as(Int64)
        total_bytes = mem_info[:total].as(Int64)
        usage_pct = mem_info[:usage_pct].as(Float64)

        case threshold.unit
        when :bytes
          limit_bytes = threshold.to_bytes
          status = used_bytes > limit_bytes ? :alert : :ok
          msg = status == :alert ? "Memory usage exceeds limit" : "Within limits"
          results << Monitor::Check.new(
            "Memory Usage",
            status,
            Info.format_bytes(used_bytes),
            threshold.format_value,
            msg
          )
        when :percent
          limit_pct = threshold.to_percent
          status = usage_pct > limit_pct ? :alert : :ok
          msg = status == :alert ? "Memory usage exceeds limit" : "Within limits"
          results << Monitor::Check.new(
            "Memory Usage",
            status,
            "%.2f%%" % usage_pct,
            "%.2f%%" % limit_pct,
            msg
          )
        end
      end
      return results
    end # check_iface



  end # Network
end # Jane
