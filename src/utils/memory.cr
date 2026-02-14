require "../info"
require "../monitor"
require "../config"

## all metrics, checks and anything related to Memory

module Jane
  module Memory
    extend self

    # -------------- INFO

    def read_memory_info : Hash(Symbol, Int64 | Float64)
      mem_total = 0_i64
      mem_free = 0_i64
      mem_available = 0_i64
      mem_buffers = 0_i64
      mem_cached = 0_i64
      swap_total = 0_i64
      swap_free = 0_i64
      File.each_line("/proc/meminfo") do |line|
        parts = line.split
        case parts[0]
        when "MemTotal:"     then mem_total = parts[1].to_i64 * 1024
        when "MemFree:"      then mem_free = parts[1].to_i64 * 1024
        when "MemAvailable:" then mem_available = parts[1].to_i64 * 1024
        when "Buffers:"      then mem_buffers = parts[1].to_i64 * 1024
        when "Cached:"       then mem_cached = parts[1].to_i64 * 1024
        when "SwapTotal:"    then swap_total = parts[1].to_i64 * 1024
        when "SwapFree:"     then swap_free = parts[1].to_i64 * 1024
        end
      end
      mem_available = mem_free + mem_buffers + mem_cached if mem_available == 0
      mem_used = mem_total - mem_available
      swap_used = swap_total - swap_free
      result = Hash(Symbol, Int64 | Float64).new
      result[:total] = mem_total
      result[:used] = mem_used
      result[:available] = mem_available
      result[:usage_pct] = (mem_used.to_f64 / mem_total.to_f64) * 100.0
      result[:swap_total] = swap_total
      result[:swap_used] = swap_used
      result[:swap_usage_pct] = swap_total > 0 ? (swap_used.to_f64 / swap_total.to_f64) * 100.0 : 0.0
      return result
    end # read_memory_info


    #----------  CHECKS

    def check_memory(mem_check : MemoryCheck) : Array(Monitor::Check)
      # checks if memory usage is above threshold
      results = [] of Monitor::Check
      mem_info = read_memory_info

      mem_check.usage.each do |threshold|
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
          break
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
          break
        end
      end
      return results
    end # check_memory




  end # Memory
end # Jane
