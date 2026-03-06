require "toml"


module Jane
  class Config

    property log : LogConfig
    property check : CheckConfig
    property hq : HQConfig? | Nil
    property defaults : DefaultsConfig
    property alert : AlertConfig?

    def initialize(@log, @check, @defaults, @hq = nil, @alert = nil)
    end

    def self.from_file(path : String) : Config
      toml = TOML.parse_file(path)
      log = LogConfig.from_toml(toml["log"])
      check = CheckConfig.from_toml(toml["check"])
      defaults = toml["defaults"]? ? DefaultsConfig.from_toml(toml["defaults"]) : DefaultsConfig.new
      hq = toml["hq"]? ? HQConfig.from_toml(toml["hq"]) : nil
      alert = toml["alert"]? ? AlertConfig.from_toml(toml["alert"]) : nil

      # Process include.checks from defaults
      defaults.include_checks.each do |pattern|
        Dir.glob(pattern).sort.each do |include_path|
          next unless File.exists?(include_path)
          begin
            inc_toml = TOML.parse_file(include_path)
            if inc_toml["check"]?
              inc_check = CheckConfig.from_toml(inc_toml["check"])
              check.merge!(inc_check)
            end
          rescue ex
            STDERR.puts "Warning: error parsing include file #{include_path}: #{ex.message}"
          end
        end
      end

      new(log, check, defaults, hq, alert)
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
    property enabled : Bool | Nil

    def initialize(@host, @port, @enabled)
    end

    def self.from_toml(data : TOML::Any) : HQConfig
      host = data["host"]?.try(&.as_s?).to_s.strip
      host = "" if host.empty?
      port_val = data["port"]?.try(&.as_i?).try(&.to_i32) || 80_i32  # default port
      enabled = data["enabled"]?.try(&.as_bool) || false
      new(host, port_val, enabled)
    end
  end

  class DefaultsConfig
    property cycle : Int32
    property alert_repeat : String
    property alert_groups : String
    property alert_users : String
    property alert_grace_seconds : Int32
    property include_checks : Array(String)

    def initialize(@cycle = 10, @alert_repeat = "yes", @alert_groups = "all", @alert_users = "all", @alert_grace_seconds = 60, @include_checks = [] of String)
    end

    def self.from_toml(data : TOML::Any) : DefaultsConfig
      cycle = data["cycle"]?.try(&.as_i?).try(&.to_i32) || 10
      alert_repeat = data["alert"]?.try { |a| a["repeat"]?.try(&.as_s) } || "yes"
      alert_groups = data["alert"]?.try { |a| a["groups"]?.try(&.as_s) } || "all"
      alert_users = data["alert"]?.try { |a| a["users"]?.try(&.as_s) } || "all"
      alert_grace_seconds = data["alert"]?.try { |a| a["grace"]?.try { |g| g["seconds"]?.try(&.as_i?).try(&.to_i32) } } || 60

      include_checks = [] of String
      if inc = data["include"]?
        if checks_val = inc["checks"]?
          if checks_val.as_s?
            include_checks = [checks_val.as_s]
          elsif checks_val.as_a?
            include_checks = checks_val.as_a.map(&.as_s)
          end
        end
      end

      new(cycle, alert_repeat, alert_groups, alert_users, alert_grace_seconds, include_checks)
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
    # Returns an array of thresholds (supports array values like usage.pct = [5,20,30]).
    def self.from_toml(data : TOML::Any, key : String) : Array(Threshold)
      # Try direct string format first: usage = "2%"
      if value = data[key]?
        if value.as_s?
          return [parse(value.as_s)]
        elsif value.as_h?
          # Handle nested format: usage.pct = 2, usage.gb = 200
          hash = value.as_h

          if pct = hash["pct"]?
            if pct.as_a?
              return pct.as_a.map { |v| new(v.as_f, :percent) }
            else
              return [new(pct.as_f, :percent)]
            end
          elsif b = hash["b"]?
            if b.as_a?
              return b.as_a.map { |v| new(v.as_f, :bytes) }
            else
              return [new(b.as_f, :bytes)]
            end
          elsif kb = hash["kb"]?
            if kb.as_a?
              return kb.as_a.map { |v| new(v.as_f * 1024, :bytes) }
            else
              return [new(kb.as_f * 1024, :bytes)]
            end
          elsif mb = hash["mb"]?
            if mb.as_a?
              return mb.as_a.map { |v| new(v.as_f * (1024 ** 2), :bytes) }
            else
              return [new(mb.as_f * (1024 ** 2), :bytes)]
            end
          elsif gb = hash["gb"]?
            if gb.as_a?
              return gb.as_a.map { |v| new(v.as_f * (1024 ** 3), :bytes) }
            else
              return [new(gb.as_f * (1024 ** 3), :bytes)]
            end
          elsif tb = hash["tb"]?
            if tb.as_a?
              return tb.as_a.map { |v| new(v.as_f * (1024 ** 4), :bytes) }
            else
              return [new(tb.as_f * (1024 ** 4), :bytes)]
            end
          elsif pb = hash["pb"]?
            if pb.as_a?
              return pb.as_a.map { |v| new(v.as_f * (1024 ** 5), :bytes) }
            else
              return [new(pb.as_f * (1024 ** 5), :bytes)]
            end
          end
        elsif value.as_i? || value.as_f?
          # Plain number without unit, treat as raw
          return [new(value.as_f, :raw)]
        end
      end

      [] of Threshold
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

  def self.parse_tags(data : TOML::Any) : Array(String)
    if tag = data["tag"]?
      if tag.as_s?
        return [tag.as_s]
      elsif tag.as_a?
        return tag.as_a.map(&.as_s)
      end
    end
    [] of String
  end

  class CheckConfig
    property cpu : CPUCheck?
    property memory : MemoryCheck?
    property filesystems : Hash(String, FilesystemCheck)
    property network_interfaces : Hash(String, InterfaceCheck)
    property network_connections : Hash(String, ConnectionCheck)
    property network_bandwidths : Hash(String, BandwidthCheck)
    property processes : Hash(String, ProcessCheck)
    property files : Hash(String, FileCheck)

    def initialize(@cpu, @memory, @filesystems, @network_interfaces, @network_connections, @network_bandwidths, @processes, @files)
    end

    def self.from_toml(data : TOML::Any) : CheckConfig
      cpu = data["cpu"]? ? CPUCheck.from_toml(data["cpu"]) : nil
      memory = data["memory"]? ? MemoryCheck.from_toml(data["memory"]) : nil

      filesystems = Hash(String, FilesystemCheck).new
      network_interfaces = Hash(String, InterfaceCheck).new
      network_connections = Hash(String, ConnectionCheck).new
      network_bandwidths = Hash(String, BandwidthCheck).new
      processes = Hash(String, ProcessCheck).new
      files = Hash(String, FileCheck).new

      data.as_h.each do |key, value|
        case key
        when "filesystem"
          value.as_h.each do |fsname, fsval|
            begin
              filesystems[fsname] = FilesystemCheck.from_toml(fsval)
            rescue ex
              raise "check.filesystem.#{fsname}: #{ex.message}"
            end
          end
        when "network"
          # network has sub-categories: interface, connection, bandwidth
          value.as_h.each do |category, entries|
            case category
            when "interface"
              entries.as_h.each do |name, entry|
                begin
                  network_interfaces[name] = InterfaceCheck.from_toml(entry)
                rescue ex
                  raise "check.network.interface.#{name}: #{ex.message}"
                end
              end
            when "connection"
              entries.as_h.each do |name, entry|
                begin
                  network_connections[name] = ConnectionCheck.from_toml(entry)
                rescue ex
                  raise "check.network.connection.#{name}: #{ex.message}"
                end
              end
            when "bandwidth"
              entries.as_h.each do |name, entry|
                begin
                  network_bandwidths[name] = BandwidthCheck.from_toml(entry)
                rescue ex
                  raise "check.network.bandwidth.#{name}: #{ex.message}"
                end
              end
            end
          end
        when "process"
          value.as_h.each do |proc_name, proc_val|
            begin
              processes[proc_name] = ProcessCheck.from_toml(proc_val)
            rescue ex
              raise "check.process.#{proc_name}: #{ex.message}"
            end
          end
        when "file"
          value.as_h.each do |file_name, file_val|
            begin
              files[file_name] = FileCheck.from_toml(file_val)
            rescue ex
              raise "check.file.#{file_name}: #{ex.message}"
            end
          end
        end
      end

      new(cpu, memory, filesystems, network_interfaces, network_connections, network_bandwidths, processes, files)
    end

    def merge!(other : CheckConfig)
      @cpu = other.cpu if other.cpu && @cpu.nil?
      @memory = other.memory if other.memory && @memory.nil?
      other.filesystems.each { |k, v| @filesystems[k] = v unless @filesystems.has_key?(k) }
      other.network_interfaces.each { |k, v| @network_interfaces[k] = v unless @network_interfaces.has_key?(k) }
      other.network_connections.each { |k, v| @network_connections[k] = v unless @network_connections.has_key?(k) }
      other.network_bandwidths.each { |k, v| @network_bandwidths[k] = v unless @network_bandwidths.has_key?(k) }
      other.processes.each { |k, v| @processes[k] = v unless @processes.has_key?(k) }
      other.files.each { |k, v| @files[k] = v unless @files.has_key?(k) }
    end
  end

  class CPUCheck
    property usage : Array(Threshold)
    property iowait : Array(Threshold)
    property loadavg : Array(Float64)?
    property tags : Array(String)

    def initialize(@usage, @iowait, @loadavg, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : CPUCheck
      usage = Threshold.from_toml(data, "usage")
      iowait = Threshold.from_toml(data, "iowait")
      loadavg = data["loadavg"]?.try { |la| la.as_a.map(&.as_f) }
      tags = Jane.parse_tags(data)

      new(usage, iowait, loadavg, tags)
    end
  end

  class MemoryCheck
    property usage : Array(Threshold)
    property tags : Array(String)

    def initialize(@usage, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : MemoryCheck
      usage = Threshold.from_toml(data, "usage")
      tags = Jane.parse_tags(data)
      new(usage, tags)
    end
  end

  class FilesystemCheck
    property path : String
    property usage : Array(Threshold)
    property tags : Array(String)

    def initialize(@path, @usage, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : FilesystemCheck
      path = data["path"].as_s
      usage = Threshold.from_toml(data, "usage")
      tags = Jane.parse_tags(data)

      new(path, usage, tags)
    end
  end # filesystem

  # ------------------------------------------------------------------
  # Network check classes
  # ------------------------------------------------------------------

  class InterfaceCheck
    property name : String?
    property interface : String
    property tags : Array(String)

    def initialize(@name, @interface, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : InterfaceCheck
      name = data["name"]?.try(&.as_s)
      # If no explicit "interface" key, derive from the TOML key name
      interface = data["interface"]?.try(&.as_s) || name || ""
      tags = Jane.parse_tags(data)
      new(name, interface, tags)
    end
  end

  class ConnectionCheck
    property name : String?
    property address : String
    property port : Int32
    property tags : Array(String)

    def initialize(@name, @address, @port, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : ConnectionCheck
      name = data["name"]?.try(&.as_s)
      address = data["address"].as_s
      port = data["port"].as_i
      tags = Jane.parse_tags(data)
      new(name, address, port, tags)
    end
  end

  class BandwidthCheck
    property name : String?
    property address : String
    property port : Int32
    property limit : Float64?
    property tags : Array(String)

    def initialize(@name, @address, @port, @limit, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : BandwidthCheck
      name = data["name"]?.try(&.as_s)
      address = data["address"].as_s
      port = data["port"]?.try(&.as_i?).try(&.to_i32) || 5201
      limit_val = data["limit"]?
      limit = if limit_val
                if limit_val.as_f?
                  limit_val.as_f
                elsif limit_val.as_i?
                  limit_val.as_i.to_f64
                elsif limit_val.as_h?
                  h = limit_val.as_h
                  if mbps = h["mbps"]?
                    mbps.as_f? || mbps.as_i?.try(&.to_f64)
                  end
                end
              end
      tags = Jane.parse_tags(data)
      new(name, address, port, limit, tags)
    end
  end


  class ProcessCheck
    property name : String?
    property bin : String?
    property match : String?
    property pidfile : String?
    property tags : Array(String)

    def initialize(@name, @bin, @match, @pidfile, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : ProcessCheck
      name = data["name"]?.try(&.as_s)
      bin = data["bin"]?.try(&.as_s)
      match = data["match"]?.try(&.as_s)
      pidfile = data["pidfile"]?.try(&.as_s)
      tags = Jane.parse_tags(data)
      puts "PROCESS CHECK bin = #{bin}"
      new(name, bin, match, pidfile, tags)
    end
  end

  class FileCheck
    property path : String
    property user : String?
    property group : String?
    property mode : String?
    property tags : Array(String)

    def initialize(@path, @user = nil, @group = nil, @mode = nil, @tags = [] of String)
    end

    def self.from_toml(data : TOML::Any) : FileCheck
      path = data["path"].as_s
      user = data["user"]?.try(&.as_s)
      group = data["group"]?.try(&.as_s)
      mode = data["mode"]?.try { |m| m.as_s? || m.as_i?.try(&.to_s) }
      tags = Jane.parse_tags(data)
      new(path, user, group, mode, tags)
    end
  end

  class AlertEmailConfig
    property smtp_server : String
    property smtp_port : Int32
    property send_to : String
    property send_cc : String?

    def initialize(@smtp_server, @smtp_port, @send_to, @send_cc = nil)
    end

    def self.from_toml(data : TOML::Any) : AlertEmailConfig
      smtp_server = data["smtp"]?.try { |s| s["server"]?.try(&.as_s) } || ""
      smtp_port = data["smtp"]?.try { |s| s["port"]?.try(&.as_i?).try(&.to_i32) } || 25
      send_to = data["send"]?.try { |s| s["to"]?.try(&.as_s) } || ""
      send_cc = data["send"]?.try { |s| s["cc"]?.try(&.as_s) }
      new(smtp_server, smtp_port, send_to, send_cc)
    end
  end

  class AlertConfig
    property email : AlertEmailConfig?

    def initialize(@email = nil)
    end

    def self.from_toml(data : TOML::Any) : AlertConfig
      email = data["email"]? ? AlertEmailConfig.from_toml(data["email"]) : nil
      new(email)
    end
  end

end # jane
