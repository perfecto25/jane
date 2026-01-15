require "tallboy"

module Jane
  module SystemInfo
    extend self

    def display
      info = gather_info
      
      table = Tallboy.table do
        header ["Property", "Value"]
        
        row ["Hostname", info[:hostname]]
        row ["OS", info[:os]]
        row ["Kernel", info[:kernel]]
        row ["Uptime", info[:uptime]]
        row ["CPU Model", info[:cpu_model]]
        row ["CPU Cores", info[:cpu_cores]]
        row ["CPU Usage", info[:cpu_usage]]
        row ["Load Average", info[:load_avg]]
        row ["Total Memory", info[:total_memory]]
        row ["Used Memory", info[:used_memory]]
        row ["Free Memory", info[:free_memory]]
        row ["Memory Usage", info[:memory_usage]]
      end
      
      puts table.render
    end

    private def gather_info : Hash(Symbol, String)
      cpu_info = read_cpu_info
      mem_info = read_memory_info
      uptime = read_uptime
      load_avg = read_loadavg
      cpu_usage = calculate_cpu_usage

      result = Hash(Symbol, String).new
      result[:hostname] = read_hostname
      result[:os] = read_os_info
      result[:kernel] = read_kernel
      result[:uptime] = format_uptime(uptime)
      result[:cpu_model] = cpu_info[:model].as(String)
      result[:cpu_cores] = cpu_info[:cores].as(Int32).to_s
      result[:cpu_usage] = "%.2f%%" % cpu_usage
      result[:load_avg] = load_avg.join(", ")
      result[:total_memory] = format_bytes(mem_info[:total].as(Int64))
      result[:used_memory] = format_bytes(mem_info[:used].as(Int64))
      result[:free_memory] = format_bytes(mem_info[:available].as(Int64))
      result[:memory_usage] = "%.2f%%" % mem_info[:usage_pct].as(Float64)
      result
    end

    def read_hostname : String
      File.read("/proc/sys/kernel/hostname").strip
    end

    def read_os_info : String
      if File.exists?("/etc/os-release")
        content = File.read("/etc/os-release")
        content.each_line do |line|
          if line.starts_with?("PRETTY_NAME=")
            return line.split("=", 2)[1].strip.gsub('"', "")
          end
        end
      end
      "Linux"
    end

    def read_kernel : String
      File.read("/proc/sys/kernel/osrelease").strip
    end

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
      result
    end

    def read_memory_info : Hash(Symbol, Int64 | Float64)
      mem_total = 0_i64
      mem_free = 0_i64
      mem_available = 0_i64
      mem_buffers = 0_i64
      mem_cached = 0_i64
      
      File.each_line("/proc/meminfo") do |line|
        parts = line.split
        case parts[0]
        when "MemTotal:"     then mem_total = parts[1].to_i64 * 1024
        when "MemFree:"      then mem_free = parts[1].to_i64 * 1024
        when "MemAvailable:" then mem_available = parts[1].to_i64 * 1024
        when "Buffers:"      then mem_buffers = parts[1].to_i64 * 1024
        when "Cached:"       then mem_cached = parts[1].to_i64 * 1024
        end
      end
      
      mem_available = mem_free + mem_buffers + mem_cached if mem_available == 0
      mem_used = mem_total - mem_available
      
      result = Hash(Symbol, Int64 | Float64).new
      result[:total] = mem_total
      result[:used] = mem_used
      result[:available] = mem_available
      result[:usage_pct] = (mem_used.to_f64 / mem_total.to_f64) * 100.0
      result
    end

    def read_uptime : Float64
      File.read("/proc/uptime").split[0].to_f64
    end

    def read_loadavg : Array(Float64)
      parts = File.read("/proc/loadavg").split
      [parts[0].to_f64, parts[1].to_f64, parts[2].to_f64]
    end

    def calculate_cpu_usage : Float64
      stat1 = read_cpu_stat
      sleep 100.milliseconds
      stat2 = read_cpu_stat
      
      total_diff = stat2[:total] - stat1[:total]
      idle_diff = stat2[:idle] - stat1[:idle]
      
      return 0.0 if total_diff == 0
      ((total_diff - idle_diff).to_f64 / total_diff.to_f64) * 100.0
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
      result[:total] = user + nice + system + idle + iowait + irq + softirq
      result
    end

    private def format_uptime(seconds : Float64) : String
      days = (seconds / 86400).to_i
      hours = ((seconds % 86400) / 3600).to_i
      minutes = ((seconds % 3600) / 60).to_i
      
      "#{days}d #{hours}h #{minutes}m"
    end

    private def format_bytes(bytes : Int64) : String
      units = ["B", "KB", "MB", "GB", "TB"]
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