require "tallboy"
require "json"
require "./jane"
require "./utils/*"

module Jane
  module Info
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
        row ["Used Memory", "#{info[:used_memory]} (#{info[:memory_usage]})"]
        row ["Free Memory", info[:free_memory]]
        if info[:swap_total]? && info[:swap_total] != "0.00 B"
          row ["Swap", "#{info[:swap_used]} / #{info[:swap_total]} (#{info[:swap_usage]})"]
        end
        row ["Jane agent version", info[:jane_version]]
      end
      puts table.render
    end


    struct Metrics
      include JSON::Serializable
      property hostname : String
      property os : String
      property kernel : String
      property uptime : String
      property cpu_model : String
      property cpu_cores : Int32
      property cpu_usage : String
      property load_avg : String
      property total_memory : String
      property used_memory : String
      property free_memory : String
      property memory_usage : String
      property jane_version : String
      def initialize(
        @hostname, @os, @kernel, @uptime, @cpu_model, @cpu_cores, @cpu_usage,
        @load_avg, @total_memory, @used_memory, @free_memory, @memory_usage, @jane_version
        )
      end
    end

    def get_metrics
      cpu_info = Cpu.read_cpu_info
      mem_info = Memory.read_memory_info
      uptime = read_uptime
      load_avg = Cpu.read_loadavg
      cpu_usage = Cpu.calculate_cpu_usage
      puts mem_info[:total]
      Metrics.new(
        hostname: read_hostname,
        os: read_os_info,
        kernel: read_kernel,
        uptime: format_uptime(uptime),
        cpu_model: cpu_info[:model].as(String),
        cpu_cores: cpu_info[:cores].as(Int32),
        cpu_usage: "%.2f%%" % cpu_usage,
        load_avg: load_avg.join(", "),
        total_memory: format_bytes(mem_info[:total].as(Int64)),
        used_memory: format_bytes(mem_info[:used].as(Int64)),
        free_memory: format_bytes(mem_info[:available].as(Int64)),
        memory_usage: "%.2f%%" % mem_info[:usage_pct].as(Float64),
        jane_version: Jane::VERSION
      )
    end


    def gather_info : Hash(Symbol, String)
      cpu_info = Cpu.read_cpu_info
      mem_info = Memory.read_memory_info
      uptime = read_uptime
      load_avg = Cpu.read_loadavg
      cpu_usage = Cpu.calculate_cpu_usage

      result = Hash(Symbol, String).new
      result[:hostname] = read_hostname
      result[:os] = read_os_info
      result[:kernel] = read_kernel
      result[:uptime] = format_uptime(uptime)
      result[:cpu_model] = cpu_info[:model].as(String)
      result[:cpu_cores] = cpu_info[:cores].as(Int32).to_s
      result[:cpu_usage] = "%.2f%%" % cpu_usage
      result[:load_avg] = load_avg.join(", ")
      result[:free_memory] = format_bytes(mem_info[:available].as(Int64))
      result[:total_memory] = format_bytes(mem_info[:total].as(Int64))
      result[:used_memory] = format_bytes(mem_info[:used].as(Int64))
      result[:memory_usage] = "%.2f%%" % mem_info[:usage_pct].as(Float64)
      swap_total = mem_info[:swap_total].as(Int64)
      if swap_total > 0
        result[:swap_total] = format_bytes(swap_total)
        result[:swap_used] = format_bytes(mem_info[:swap_used].as(Int64))
        result[:swap_usage] = "%.2f%%" % mem_info[:swap_usage_pct].as(Float64)
      end
      result[:jane_version] = Jane::VERSION
      return result
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

    def read_uptime : Float64
      File.read("/proc/uptime").split[0].to_f64
    end

    private def format_uptime(seconds : Float64) : String
      days = (seconds / 86400).to_i
      hours = ((seconds % 86400) / 3600).to_i
      minutes = ((seconds % 3600) / 60).to_i
      return "#{days}d #{hours}h #{minutes}m"
    end

    def format_bytes(bytes : Int64) : String
      units = ["B", "KB", "MB", "GB", "TB"]
      size = bytes.to_f64
      unit_idx = 0

      while size >= 1024.0 && unit_idx < units.size - 1
        size /= 1024.0
        unit_idx += 1
      end
      return "%.2f %s" % [size, units[unit_idx]]
    end
  end
end
