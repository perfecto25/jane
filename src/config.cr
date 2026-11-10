require "colorize"
require "./rules/policy"
require "./conf/ast"

module Jane
  # Control file used when no -c/--config is given.
  DEFAULT_CONFIG = "jane.conf"

  class Config

    property log : LogConfig
    property check : CheckConfig
    property hq : HQConfig? | Nil
    property defaults : DefaultsConfig
    property alert : AlertConfig?

    def initialize(@log, @check, @defaults, @hq = nil, @alert = nil)
    end

    # Loads a Monit-style control file (see docs/control-file.md), printing
    # warnings, or aborts with the error.
    def self.from_file(path : String) : Config
      config, warnings = load(path)
      warnings.each { |w| STDERR.puts "⚠  Warning: #{w}".colorize(:yellow) }
      config
    rescue ex
      abort "Error parsing config file: #{ex.message}"
    end

    # Loads a config without printing or aborting. Returns the config and any
    # warnings as "file:line:col: message" strings. Raises on errors.
    def self.load(path : String) : Tuple(Config, Array(String))
      raise "config file not found: #{path}" unless File.exists?(path)
      if path.ends_with?(".toml")
        raise "#{path}: TOML configs are no longer supported, use a Monit-style control file (jane -g prints a starter one; see docs/control-file.md)"
      end
      config, warnings = Conf.load(path)
      {config, warnings.map { |pos, msg| "#{pos}: #{msg}" }}
    end
  end

  class LogConfig
    property destination : String
    property file : String?
    property level : String

    def initialize(@destination, @file, @level)
    end
  end

  class HQConfig
    property host : String | Nil
    property port : Int32 | Nil
    property enabled : Bool | Nil

    def initialize(@host, @port, @enabled)
    end
  end

  class DefaultsConfig
    property cycle : Int32 # `set cycle <seconds>`

    def initialize(@cycle = 10)
    end
  end

  struct Threshold
    property value : Float64
    property unit : Symbol  # :percent, :bytes, or :raw
    property policy : Policy # from the rule's cycles and action

    def initialize(@value, @unit, @policy = Policy.new)
    end

    # Short form used to tell threshold levels apart in check names: "80%", "5.00 GB", "1.5"
    def label : String
      case @unit
      when :percent
        @value == @value.to_i64 ? "#{@value.to_i64}%" : "#{@value}%"
      when :bytes
        format_bytes(@value.to_i64)
      else
        @value == @value.to_i64 ? @value.to_i64.to_s : @value.to_s
      end
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
    property network_interfaces : Hash(String, InterfaceCheck)
    property network_connections : Hash(String, ConnectionCheck)
    property network_bandwidths : Hash(String, BandwidthCheck)
    property processes : Hash(String, ProcessCheck)
    property files : Hash(String, FileCheck)
    property programs : Hash(String, ProgramCheck)

    def initialize(@cpu, @memory, @filesystems, @network_interfaces, @network_connections, @network_bandwidths, @processes, @files,
                   @programs = {} of String => ProgramCheck)
    end
  end

  class CPUCheck
    property every : Int32 = 1 # run every N cycles
    property usage : Array(Threshold)
    property iowait : Array(Threshold)
    property loadavg : Array(Array(Threshold)) # levels per period: [1min, 5min, 15min]
    # Same, divided by the number of online CPUs (`loadavg (5min) per core`)
    property loadavg_per_core : Array(Array(Threshold)) = [[] of Threshold, [] of Threshold, [] of Threshold]
    property tags : Array(String)

    def initialize(@usage, @iowait, @loadavg, @tags = [] of String)
    end
  end

  class MemoryCheck
    property every : Int32 = 1 # run every N cycles
    property usage : Array(Threshold)
    property swap : Array(Threshold)
    property tags : Array(String)

    def initialize(@usage, @tags = [] of String, @swap = [] of Threshold)
    end
  end

  class FilesystemCheck
    property every : Int32 = 1 # run every N cycles
    property path : String
    property usage : Array(Threshold)
    property tags : Array(String)
    property rules = [] of FilesystemRule # inode usage/free, space free, changed fsflags
    # Like Monit, `path` must be a mount point or a mounted device.

    def initialize(@path, @usage, @tags = [] of String)
    end

  end # filesystem

  # ------------------------------------------------------------------
  # Network check classes
  # ------------------------------------------------------------------

  class InterfaceCheck
    property every : Int32 = 1 # run every N cycles
    property policy : Policy = Policy.new
    property name : String?
    property interface : String
    property tags : Array(String)

    def initialize(@name, @interface, @tags = [] of String)
    end
  end

  class ConnectionCheck
    property every : Int32 = 1 # run every N cycles
    property policy : Policy = Policy.new
    property name : String?
    property address : String
    property port : Int32
    property tags : Array(String)
    property expect : Regex? = nil # first line the server sends must match
    property probe : PortProbe? = nil # TLS, HTTP and certificate options

    def initialize(@name, @address, @port, @tags = [] of String)
    end
  end

  class BandwidthCheck
    property every : Int32 = 1 # run every N cycles
    property policy : Policy = Policy.new
    property name : String?
    property address : String
    property port : Int32
    property limit : Float64?
    property tags : Array(String)

    def initialize(@name, @address, @port, @limit, @tags = [] of String)
    end
  end

  class ProcessCheck
    property every : Int32 = 1 # run every N cycles
    property policy : Policy = Policy.new
    property name : String?
    property match : String?
    property pidfile : String?
    property tags : Array(String)
    property rules = [] of ProcessRule # resource tests

    def initialize(@name, @match, @pidfile, @tags = [] of String)
    end
  end

  class FileCheck
    property every : Int32 = 1 # run every N cycles
    property path : String
    property user : String?
    property group : String?
    property mode : String?
    property tags : Array(String)
    property content_rules = [] of ContentRule
    property policies = {} of String => Policy # keyed by "exist", "user", "group", "mode"
    property rules = [] of FileRule            # timestamp, size, checksum
    # :file, :directory or :fifo: the path must be of that type
    property kind : Symbol = :file

    # Name prefix of the results: "File x", "Directory x", "Fifo x".
    def prefix : String
      case @kind
      when :directory then "Directory"
      when :fifo      then "Fifo"
      else                 "File"
      end
    end

    def initialize(@path, @user = nil, @group = nil, @mode = nil, @tags = [] of String)
    end
  end

  # Timestamp, size and checksum tests on a file/directory/fifo:
  #   timestamp, modify timestamp, change timestamp, access timestamp
  #       value: age in seconds; op Changed: fires in the cycle the time changes.
  #       Plain `timestamp` is the newer of modify and change time, like Monit.
  #   size      value: bytes; op Changed as above
  #   checksum  op NE: fails while the hash differs from `expect` (or, without
  #             `expect`, from the hash seen when Jane started);
  #             op Changed: fires in the cycle the hash changes
  class FileRule
    getter test : String
    getter op : Conf::Op
    getter value : Float64
    getter algorithm : String # md5, sha1, sha256 (checksum only)
    getter expect : String?
    getter policy : Policy

    def initialize(@test, @op, @value = 0.0, @policy = Policy.new, @algorithm = "md5", @expect = nil)
    end

    def label : String
      case @test
      when "checksum"
        @op.changed? ? "#{@algorithm} checksum changed" : "#{@algorithm} checksum"
      when "size"
        @op.changed? ? "size changed" : "size #{Jane.op_symbol(@op)} #{Jane.format_size(@value)}"
      else
        @op.changed? ? "#{@test} changed" : "#{@test} #{Jane.op_symbol(@op)} #{Jane.format_duration(@value)}"
      end
    end
  end

  # `if content = "<regex>"` on a file: matched against lines appended since
  # the previous cycle. `=` fires when a new line matches, `!=` when a new line
  # doesn't match.
  class ContentRule
    getter op : Conf::Op
    getter pattern : Regex
    getter policy : Policy

    def initialize(@op, @pattern, @policy = Policy.new)
    end

    def label : String
      "#{@op.ne? ? "!=" : "="} #{@pattern.source.inspect}"
    end
  end

  # Filesystem tests besides `space usage`:
  #   space free    value: bytes (unit :bytes) or percent
  #   inode usage   value: count (unit :count) or percent
  #   inode free    value: count or percent
  #   fsflags       op Changed: fires in the cycle the mount options change (e.g. rw → ro)
  class FilesystemRule
    getter test : String
    getter op : Conf::Op
    getter value : Float64
    getter unit : Symbol
    getter policy : Policy

    def initialize(@test, @op, @value = 0.0, @unit = :count, @policy = Policy.new)
    end

    def label : String
      return "fsflags changed" if @op.changed?
      value = case @unit
              when :percent then "#{Jane.trim_float(@value)}%"
              when :bytes   then Threshold.new(@value, :bytes).label
              else               Jane.trim_float(@value)
              end
      "#{@test} #{Jane.op_symbol(@op)} #{value}"
    end
  end

  # A port test: `if failed [host X] port N [type tcpssl] [protocol http|https]
  # [request "/path"] [hostheader "h"] [status <op> N] [content = "re"]
  # [expect "re"] [certificate valid > N days] [timeout N seconds]
  # [ssl options {verify: enable}]`. Passes when every condition holds.
  class PortProbe
    property address : String
    property port : Int32
    property ssl : Bool = false          # type tcpssl / protocol https
    property http : Bool = false         # protocol http / https
    property request : String = "/"
    property host_header : String? = nil
    property status_op : Conf::Op? = nil # default: status < 400
    property status : Int32 = 0
    property content_op : Conf::Op? = nil # EQ: body must match; NE: must not match
    property content : Regex? = nil
    property expect : Regex? = nil       # first line from the server (non-HTTP)
    property cert_op : Conf::Op? = nil   # certificate valid <op> cert_days
    property cert_days : Float64 = 0.0
    property verify : Bool = false       # verify the certificate chain and hostname (Monit's default: off)
    property timeout : Int32? = nil      # seconds; default: the daemon cycle - 1

    def initialize(@address, @port, @expect = nil)
    end

    def protocol_name : String
      @http ? (@ssl ? "https" : "http") : (@ssl ? "tcpssl" : "tcp")
    end
  end

  # A resource test on a running process:
  #   cpu / total cpu         value in percent of the whole machine
  #   memory / total memory   value in bytes (unit :bytes) or percent of RAM
  #   threads / children      count
  #   uptime                  seconds
  #   pid / ppid              op Changed: fires in the cycle the value changes
  #   port                    value is the port; fires when the connection fails
  #   disk read / disk write  per second: bytes (unit :bytes_rate) or operations (:ops_rate);
  #   total disk read / write  "total" includes all descendants
  class ProcessRule
    getter test : String
    getter op : Conf::Op
    getter value : Float64
    getter unit : Symbol # :percent, :bytes, :count, :seconds, :bytes_rate, :ops_rate
    getter policy : Policy
    getter probe : PortProbe? # port tests

    def initialize(@test, @op, @value = 0.0, @unit = :count, @policy = Policy.new, @probe = nil)
    end

    def label : String
      case @test
      when "pid", "ppid" then "#{@test} changed"
      when "port"        then "port #{@value.to_i}"
      else                    "#{@test} #{Jane.op_symbol(@op)} #{format_value}"
      end
    end

    def format_value : String
      case @unit
      when :percent then "#{Jane.trim_float(@value)}%"
      when :bytes   then Threshold.new(@value, :bytes).label
      when :seconds    then Jane.format_duration(@value)
      when :bytes_rate then "#{Threshold.new(@value, :bytes).label}/s"
      when :ops_rate   then "#{Jane.trim_float(@value)} ops/s"
      else                  Jane.trim_float(@value)
      end
    end
  end

  def self.op_symbol(op : Conf::Op) : String
    case op
    when .gt? then ">"
    when .ge? then ">="
    when .lt? then "<"
    when .le? then "<="
    when .ne? then "!="
    when .eq? then "="
    else           "changed"
    end
  end

  def self.compare(value : Float64, op : Conf::Op, limit : Float64) : Bool
    case op
    when .gt? then value > limit
    when .ge? then value >= limit
    when .lt? then value < limit
    when .le? then value <= limit
    when .ne? then value != limit
    when .eq? then value == limit
    else           false
    end
  end

  # 6 → "6 B", 2048 → "2.00 KB"
  def self.format_size(bytes : Float64) : String
    bytes < 1024 ? "#{bytes.to_i64} B" : Threshold.new(bytes, :bytes).label
  end

  def self.trim_float(v : Float64) : String
    v == v.to_i64 ? v.to_i64.to_s : v.round(2).to_s
  end

  # 90 → "90s", 300 → "5m", 7200 → "2h", 172800 → "2d", 5400 → "1h 30m"
  def self.format_duration(seconds : Float64) : String
    s = seconds.to_i64
    parts = [] of String
    {86400 => "d", 3600 => "h", 60 => "m"}.each do |size, unit|
      if s >= size
        parts << "#{s // size}#{unit}"
        s %= size
      end
    end
    parts << "#{s}s" if s > 0 || parts.empty?
    parts.first(2).join(" ")
  end

  # One `if status ...` or `if content ...` rule of a `check program`.
  class ProgramRule
    getter test : String        # "status" or "content"
    getter op : Conf::Op
    getter number : Float64?    # status
    getter pattern : Regex?     # content
    getter policy : Policy

    def initialize(@test, @op, @number = nil, @pattern = nil, @policy = Policy.new)
    end

    def label : String
      op = Jane.op_symbol(@op)
      value = if n = @number
                n == n.to_i64 ? n.to_i64.to_s : n.to_s
              else
                @pattern.not_nil!.source.inspect
              end
      "#{@test} #{op} #{value}"
    end
  end

  # `check program <name> with path "<command>"`
  class ProgramCheck
    property command : String
    property timeout : Int32?   # seconds; default: the daemon cycle
    property rules : Array(ProgramRule)
    property tags : Array(String)
    property every : Int32 = 1
    property policy : Policy = Policy.new # for the timeout result

    def initialize(@command, @timeout = nil, @rules = [] of ProgramRule, @tags = [] of String)
    end
  end

  class AlertEmailConfig
    property smtp_server : String
    property smtp_port : Int32
    property send_to : String
    property send_cc : String?

    def initialize(@smtp_server, @smtp_port, @send_to, @send_cc = nil)
    end
  end

  class AlertConfig
    property email : AlertEmailConfig?

    def initialize(@email = nil)
    end
  end

end # jane

require "./conf/parser"
require "./conf/builder"
