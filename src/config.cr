require "toml"

module Jane
  class Config
    property log : LogConfig
    property check : CheckConfig
    property hq : HQConfig?|Nil

    def initialize(@log, @check, @hq = nil)
    end

    def self.from_file(path : String) : Config
      toml = TOML.parse_file(path)
      log = LogConfig.from_toml(toml["log"])
      check = CheckConfig.from_toml(toml["check"])
      hq = toml["hq"]? ? HQConfig.from_toml(toml["hq"]) : nil
      new(log, check, hq)
    rescue ex
      abort "Error parsing config file: #{ex.message}"
    end
  end

  class LogConfig
    property destination : String
    property file : String?
    property level : String

    def initialize(@destination, @file, @level)
    end

    def self.from_toml(data : TOML::Any) : LogConfig
      new(data["destination"].as_s, data["file"]?.try(&.as_s), data["level"].as_s)
    end # from_toml
  end

  class HQConfig
    property host : String | Nil
    property port : Int32 | Nil

    def initialize(@host, @port)
    end

    def self.from_toml(data : TOML::Any) : HQConfig
      host = data["host"]?.try(&.as_s?).to_s.strip
      host = "" if host.empty?
      port_val = data["port"]?.try(&.as_i?).try(&.to_i32) || 80_i32  # default port
      new(host, port_val)
    end
  end

  struct Threshold
    property value : Float64
    property unit : Symbol  # :percent, :bytes, or :raw

    def initialize(@value, @unit)
    end

    # Parse string format like "2%", "200mb", "300gb"
    def self.parse(str : String) : Threshold
      str = str.downcase.strip

      # Check for percentage
      if str.ends_with?("%")
        value = str.rchop.to_f64
        return new(value, :percent)
      end

      # Check for byte units
      if str =~ /(\d+(?:\.\d+)?)\s*(b|kb|mb|gb|tb|pb)?$/i
        matches = str.match(/(\d+(?:\.\d+)?)\s*(b|kb|mb|gb|tb|pb)?$/i)
        return new(0.0, :bytes) unless matches

        value = matches[1].to_f64
        unit = matches[2]?.try(&.downcase) || "b"

        multiplier = case unit
        when "b"  then 1_i64
        when "kb" then 1024_i64
        when "mb" then 1024_i64 ** 2
        when "gb" then 1024_i64 ** 3
        when "tb" then 1024_i64 ** 4
        when "pb" then 1024_i64 ** 5
        else 1_i64
        end

        return new(value * multiplier, :bytes)
      end

      # Default to raw number
      new(str.to_f64, :raw)
    end

    # Parse from TOML nested structure like usage.pct, usage.gb, etc.
    def self.from_toml(data : TOML::Any, key : String) : Threshold?
      # Try direct string format first: usage = "2%"
      if value = data[key]?
        if value.as_s?
          return parse(value.as_s)
        elsif value.as_h?
          # Handle nested format: usage.pct = 2, usage.gb = 200
          hash = value.as_h

          if pct = hash["pct"]?
            return new(pct.as_f, :percent)
          elsif b = hash["b"]?
            return new(b.as_f, :bytes)
          elsif kb = hash["kb"]?
            return new(kb.as_f * 1024, :bytes)
          elsif mb = hash["mb"]?
            return new(mb.as_f * (1024 ** 2), :bytes)
          elsif gb = hash["gb"]?
            return new(gb.as_f * (1024 ** 3), :bytes)
          elsif tb = hash["tb"]?
            return new(tb.as_f * (1024 ** 4), :bytes)
          elsif pb = hash["pb"]?
            return new(pb.as_f * (1024 ** 5), :bytes)
          end
        elsif value.as_i? || value.as_f?
          # Plain number without unit, treat as raw
          return new(value.as_f, :raw)
        end
      end

      nil
    end

    def to_percent : Float64
      raise "Not a percentage threshold" unless @unit == :percent
      @value
    end

    def to_bytes : Int64
      raise "Not a bytes threshold" unless @unit == :bytes
      @value.to_i64
    end

    def to_gb : Float64
      raise "Not a bytes threshold" unless @unit == :bytes
      @value / (1024.0 ** 3)
    end

    def format_value : String
      case @unit
      when :percent
        "%.2f%%" % @value
      when :bytes
        format_bytes(@value.to_i64)
      else
        "%.2f" % @value
      end
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

  class CheckConfig
    property cpu : CPUCheck?
    property memory : MemoryCheck?
    property filesystems : Hash(String, FilesystemCheck)

    def initialize(@cpu, @memory, @filesystems)
    end

    def self.from_toml(data : TOML::Any) : CheckConfig
      cpu = data["cpu"]? ? CPUCheck.from_toml(data["cpu"]) : nil
      memory = data["memory"]? ? MemoryCheck.from_toml(data["memory"]) : nil

      filesystems = Hash(String, FilesystemCheck).new
      data.as_h.each do |key, value|
        if key.starts_with?("filesystem.")
          name = key.sub("filesystem.", "")
          filesystems[name] = FilesystemCheck.from_toml(value)
        end
      end

      new(cpu, memory, filesystems)
    end
  end

  class CPUCheck
    property usage : Threshold?
    property iowait : Threshold?
    property loadavg : Array(Float64)?

    def initialize(@usage, @iowait, @loadavg)
    end

    def self.from_toml(data : TOML::Any) : CPUCheck
      usage = Threshold.from_toml(data, "usage")
      iowait = Threshold.from_toml(data, "iowait")
      loadavg = data["loadavg"]?.try { |la| la.as_a.map(&.as_f) }

      new(usage, iowait, loadavg)
    end
  end

  class MemoryCheck
    property usage : Threshold?

    def initialize(@usage)
    end

    def self.from_toml(data : TOML::Any) : MemoryCheck
      usage = Threshold.from_toml(data, "usage")
      new(usage)
    end
  end

  class FilesystemCheck
    property path : String
    property usage : Threshold?

    def initialize(@path, @usage)
    end

    def self.from_toml(data : TOML::Any) : FilesystemCheck
      path = data["path"].as_s
      usage = Threshold.from_toml(data, "usage")

      new(path, usage)
    end
  end
end
