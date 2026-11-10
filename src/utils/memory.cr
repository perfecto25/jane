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
      # checks if memory usage is above threshold; one row per threshold level
      results = [] of Monitor::Check
      mem_info = read_memory_info
      used_bytes = mem_info[:used].as(Int64)
      usage_pct = mem_info[:usage_pct].as(Float64)
      levels = mem_check.usage.select { |t| t.unit == :bytes || t.unit == :percent }

      levels.each do |threshold|
        if threshold.unit == :bytes
          status = used_bytes > threshold.to_bytes ? :alert : :ok
          current = Info.format_bytes(used_bytes)
          limit = threshold.format_value
        else
          status = usage_pct > threshold.to_percent ? :alert : :ok
          current = "%.2f%%" % usage_pct
          limit = "%.2f%%" % threshold.to_percent
        end
        results << Monitor.level_check("Memory Usage", threshold, levels,
          status, current, limit,
          status == :alert ? "Memory usage exceeds limit" : "Within limits")
      end

      swap_levels = mem_check.swap.select { |t| t.unit == :bytes || t.unit == :percent }
      swap_total = mem_info[:swap_total].as(Int64)
      swap_used = mem_info[:swap_used].as(Int64)
      swap_pct = mem_info[:swap_usage_pct].as(Float64)
      swap_levels.each do |threshold|
        if swap_total == 0
          results << Monitor.level_check("Swap Usage", threshold, swap_levels, :ok, "n/a",
            threshold.unit == :bytes ? threshold.format_value : "%.2f%%" % threshold.to_percent, "No swap configured")
          next
        end
        if threshold.unit == :bytes
          status = swap_used > threshold.to_bytes ? :alert : :ok
          current = Info.format_bytes(swap_used)
          limit = threshold.format_value
        else
          status = swap_pct > threshold.to_percent ? :alert : :ok
          current = "%.2f%%" % swap_pct
          limit = "%.2f%%" % threshold.to_percent
        end
        results << Monitor.level_check("Swap Usage", threshold, swap_levels, status, current, limit,
          status == :alert ? "Swap usage exceeds limit (#{Info.format_bytes(swap_used)} of #{Info.format_bytes(swap_total)})" : "Within limits")
      end
      return results
    end # check_memory




  end # Memory
end # Jane
