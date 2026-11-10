require "./ast"
require "../config"

## builder.cr — maps a parsed control file (Conf::Document) onto Jane::Config
##
## Each rule becomes a threshold/check plus a Policy (cycle window and the
## commands its action runs), which the Engine applies at run time. Anything
## Jane can't honour yet is reported as a warning with its source position
## instead of being silently dropped.

module Jane
  module Conf
    class Builder
      LOG_LEVELS = %w(debug info warn error fatal)

      BYTE_UNITS = {
        "b" => 1_i64, "kb" => 1024_i64, "k" => 1024_i64,
        "mb" => 1024_i64 ** 2, "m" => 1024_i64 ** 2,
        "gb" => 1024_i64 ** 3, "g" => 1024_i64 ** 3,
        "tb" => 1024_i64 ** 4, "t" => 1024_i64 ** 4,
        "pb" => 1024_i64 ** 5,
      }

      LOADAVG_PERIODS = {"1min" => 0, "5min" => 1, "15min" => 2}

      getter warnings : Array(Tuple(Pos, String))

      def initialize(@doc : Document, @warnings = [] of Tuple(Pos, String))
        @cycle = 10
        @log = LogConfig.new("syslog", nil, "info")
        @hq = nil.as(HQConfig?)
        @mail_server = nil.as(Setting?)
        @alert_to = [] of Setting

        @cpu = nil.as(CPUCheck?)
        @memory = nil.as(MemoryCheck?)
        @filesystems = {} of String => FilesystemCheck
        @interfaces = {} of String => InterfaceCheck
        @connections = {} of String => ConnectionCheck
        @bandwidths = {} of String => BandwidthCheck
        @processes = {} of String => ProcessCheck
        @files = {} of String => FileCheck
        @programs = {} of String => ProgramCheck
      end

      def build : Config
        @doc.settings.each { |s| apply_setting(s) }

        seen = {} of String => Service
        @doc.services.each do |svc|
          if prev = seen[svc.name]?
            raise ParseError.new("duplicate service name '#{svc.name}' (first defined at #{prev.pos})", svc.pos)
          end
          seen[svc.name] = svc
          build_service(svc)
        end

        checks = CheckConfig.new(@cpu, @memory, @filesystems, @interfaces, @connections, @bandwidths, @processes, @files, @programs)
        defaults = DefaultsConfig.new(cycle: @cycle)
        Config.new(@log, checks, defaults, @hq, build_alert)
      end

      # ---------------------------------------------------------------- settings

      private def apply_setting(s : Setting)
        case s.key
        when "cycle"
          @cycle = s.value.to_i
          warn(s.pos, "'start delay' is not supported and was ignored") if s.args["start_delay"]?
        when "log"
          level = s.args["level"]?.try(&.downcase) || "info"
          unless LOG_LEVELS.includes?(level)
            raise ParseError.new("unknown log level '#{level}', expected one of: #{LOG_LEVELS.join(", ")}", s.pos)
          end
          warn(s.pos, "syslog 'facility' is not supported and was ignored") if s.args["facility"]?
          @log = if s.value.downcase == "syslog"
                   LogConfig.new("syslog", nil, level)
                 else
                   LogConfig.new("file", s.value, level)
                 end
        when "hq"
          @hq = HQConfig.new(s.value, (s.args["port"]? || "80").to_i32, true)
        when "mailserver"
          @mail_server = s
        when "alert"
          @alert_to << s
        end
      end

      private def build_alert : AlertConfig?
        return nil if @alert_to.empty? && @mail_server.nil?

        server = @mail_server
        if server.nil?
          warn(@alert_to.first.pos, "'set alert' without 'set mailserver': email alerts are disabled")
          return nil
        end
        if @alert_to.empty?
          warn(server.pos, "'set mailserver' without 'set alert': no one will receive email alerts")
          return nil
        end

        # Jane's mailer takes one To and one Cc address.
        first = @alert_to.first
        to = first.value
        cc = first.args["cc"]? || @alert_to[1]?.try(&.value)
        extra = @alert_to.size - (first.args["cc"]? ? 1 : 2)
        if extra > 0
          warn(@alert_to.last.pos, "only one alert recipient plus one cc are supported; #{extra} more recipient(s) ignored")
        end

        port = (server.args["port"]? || "25").to_i32
        AlertConfig.new(AlertEmailConfig.new(server.value, port, to, cc))
      end

      # ---------------------------------------------------------------- services

      SUPPORTED_TYPES = %w(system filesystem file directory fifo process program host network bandwidth)

      private def build_service(svc : Service)
        unless SUPPORTED_TYPES.includes?(svc.type)
          warn(svc.pos, "'check #{svc.type}' is not supported yet; '#{svc.name}' was skipped")
          return
        end
        warn(svc.pos, "'depends on' is not supported yet and was ignored") unless svc.depends.empty?
        every = every_cycles(svc)

        case svc.type
        when "system"     then build_system(svc, every)
        when "filesystem" then build_filesystem(svc, every)
        when "file"       then build_file(svc, every, :file)
        when "directory"  then build_file(svc, every, :directory)
        when "fifo"       then build_file(svc, every, :fifo)
        when "process"    then build_process(svc, every)
        when "program"    then build_program(svc, every)
        when "host"       then build_host(svc, every)
        when "network"    then build_network(svc, every)
        when "bandwidth"  then build_bandwidth(svc, every)
        end
      end

      private def every_cycles(svc : Service) : Int32
        spec = svc.every
        return 1 unless spec
        if n = spec.to_i?
          raise ParseError.new("'every' needs at least 1 cycle", svc.pos) if n < 1
          n
        else
          warn(svc.pos, "cron-style 'every \"#{spec}\"' is not supported yet; '#{svc.name}' is checked every cycle")
          1
        end
      end

      private def build_system(svc : Service, every : Int32)
        if @cpu || @memory
          raise ParseError.new("only one 'check system' is allowed", svc.pos)
        end
        usage = [] of Threshold
        iowait = [] of Threshold
        loadavg = [[] of Threshold, [] of Threshold, [] of Threshold]
        per_core = [[] of Threshold, [] of Threshold, [] of Threshold]
        memory = [] of Threshold
        swap = [] of Threshold

        svc.rules.each do |rule|
          case rule.test
          when "cpu", "cpu usage"
            next unless greater_than?(rule)
            arg = rule.arg.try(&.downcase)
            if arg && arg != "wait"
              warn(rule.pos, "cpu (#{arg}) is not supported yet, only total cpu and cpu (wait); rule skipped")
              next
            end
            (arg == "wait" ? iowait : usage).concat(thresholds(svc, rule, percent_only: true))
          when "cpu wait", "iowait"
            next unless greater_than?(rule)
            iowait.concat(thresholds(svc, rule, percent_only: true))
          when "memory", "memory usage"
            next unless greater_than?(rule)
            memory.concat(thresholds(svc, rule))
          when "swap", "swap usage"
            next unless greater_than?(rule)
            swap.concat(thresholds(svc, rule))
          when "loadavg", "loadavg per core"
            next unless greater_than?(rule)
            period = (rule.arg || "1min").downcase
            idx = LOADAVG_PERIODS[period]?
            unless idx
              raise ParseError.new("unknown loadavg period '#{period}', expected 1min, 5min or 15min", rule.pos)
            end
            policy = policy_for(svc, rule)
            rule.values.each do |v|
              n = v.num
              raise ParseError.new("loadavg needs a number, got #{v}", rule.pos) if n.nil? || v.unit
              (rule.test == "loadavg" ? loadavg : per_core)[idx] << Threshold.new(n, :raw, policy)
            end
          else
            unsupported_test(svc, rule)
          end
        end

        unless usage.empty? && iowait.empty? && loadavg.all?(&.empty?) && per_core.all?(&.empty?)
          cpu = CPUCheck.new(levels(usage, svc), levels(iowait, svc), loadavg.map { |l| levels(l, svc) }, svc.tags.dup)
          cpu.loadavg_per_core = per_core.map { |l| levels(l, svc) }
          cpu.every = every
          @cpu = cpu
        end
        unless memory.empty? && swap.empty?
          mem = MemoryCheck.new(levels(memory, svc), svc.tags.dup, levels(swap, svc))
          mem.every = every
          @memory = mem
        end
        warn(svc.pos, "'check system #{svc.name}' has no supported rules") if @cpu.nil? && @memory.nil?
      end

      private def build_filesystem(svc : Service, every : Int32)
        path = require_attr(svc, "path")
        usage = [] of Threshold
        rules = [] of FilesystemRule
        svc.rules.each do |rule|
          case rule.test
          when "space", "space usage", "usage"
            next unless greater_than?(rule)
            usage.concat(thresholds(svc, rule))
          when "space free"
            amount, unit = percent_or(rule, :bytes)
            rules << FilesystemRule.new("space free", comparison(rule), amount, unit, policy_for(svc, rule))
          when "inode", "inodes", "inode usage"
            amount, unit = percent_or(rule, :count)
            rules << FilesystemRule.new("inode usage", comparison(rule), amount, unit, policy_for(svc, rule))
          when "inode free", "inodes free"
            amount, unit = percent_or(rule, :count)
            rules << FilesystemRule.new("inode free", comparison(rule), amount, unit, policy_for(svc, rule))
          when "fsflags", "fsflag", "fs flags", "flags"
            unless rule.op == Op::Changed
              raise ParseError.new("'#{rule.test}' can only be tested for change: 'if changed fsflags then ...'", rule.pos)
            end
            rules << FilesystemRule.new("fsflags", Op::Changed, policy: policy_for(svc, rule))
          else
            unsupported_test(svc, rule)
          end
        end
        if usage.empty? && rules.empty?
          warn(svc.pos, "'check filesystem #{svc.name}' has no rules; only checks that '#{path}' is mounted")
        end
        fs = FilesystemCheck.new(path, levels(usage, svc), svc.tags.dup)
        fs.rules = rules
        fs.every = every
        @filesystems[svc.name] = fs
      end

      # 10% → {10.0, :percent}; otherwise a size (other = :bytes) or a count (:count).
      private def percent_or(rule : Rule, other : Symbol) : Tuple(Float64, Symbol)
        v = single_number(rule)
        n = v.num.not_nil!
        return {n, :percent} if v.unit == "%"
        if other == :bytes
          {bytes(rule), :bytes}
        else
          raise ParseError.new("'#{rule.test}' needs a percentage or a count, got #{v}", rule.pos) if v.unit
          {n, :count}
        end
      end

      TIMESTAMP_TESTS = ["timestamp", "modify timestamp", "change timestamp", "access timestamp"]
      CHECKSUM_ALGORITHMS = {"md5" => 32, "sha1" => 40, "sha256" => 64}

      private def build_file(svc : Service, every : Int32, kind : Symbol)
        path = require_attr(svc, "path")
        file = FileCheck.new(path, tags: svc.tags.dup)
        file.every = every
        file.kind = kind
        svc.rules.each do |rule|
          # size, checksum and content only make sense for regular files
          if kind != :file && (rule.test.includes?("checksum") || rule.test.in?("size", "content", "failed md5", "failed sha1", "failed sha256"))
            raise ParseError.new("'#{rule.test}' only works on 'check file', not 'check #{svc.type}'", rule.pos)
          end
          case rule.test
          when .in?(TIMESTAMP_TESTS)
            if rule.op == Op::Changed
              file.rules << FileRule.new(rule.test, Op::Changed, policy: policy_for(svc, rule))
            else
              file.rules << FileRule.new(rule.test, comparison(rule), seconds(rule), policy_for(svc, rule))
            end
          when "size"
            if rule.op == Op::Changed
              file.rules << FileRule.new("size", Op::Changed, policy: policy_for(svc, rule))
            else
              file.rules << FileRule.new("size", comparison(rule), bytes(rule), policy_for(svc, rule))
            end
          when "checksum", "md5 checksum", "sha1 checksum", "sha256 checksum"
            unless rule.op == Op::Changed
              raise ParseError.new("use 'if changed #{rule.test}' or 'if failed #{rule.test} expect \"<hash>\"'", rule.pos)
            end
            algorithm = rule.test == "checksum" ? "md5" : rule.test.split.first
            file.rules << FileRule.new("checksum", Op::Changed, policy: policy_for(svc, rule), algorithm: algorithm)
          when "failed checksum", "failed md5", "failed sha1", "failed sha256"
            algorithm, expect = checksum_args(rule)
            file.rules << FileRule.new("checksum", Op::NE, policy: policy_for(svc, rule), algorithm: algorithm, expect: expect)
          when "not exist"
            file.policies["exist"] = policy_for(svc, rule)
          when "failed uid", "failed owner"
            file.user = single_arg(rule)
            file.policies["user"] = policy_for(svc, rule)
          when "failed gid", "failed group"
            file.group = single_arg(rule)
            file.policies["group"] = policy_for(svc, rule)
          when "failed permission", "failed perm"
            m = single_arg(rule).lstrip('0')
            unless m =~ /\A[0-7]{3,4}\z/
              raise ParseError.new("permission must be octal (e.g. 644), got '#{single_arg(rule)}'", rule.pos)
            end
            file.mode = m
            file.policies["mode"] = policy_for(svc, rule)
          when "content"
            file.content_rules << ContentRule.new(content_op(rule), regex(rule), policy_for(svc, rule))
          else
            unsupported_test(svc, rule)
          end
        end
        @files[svc.name] = file
      end

      private def build_process(svc : Service, every : Int32)
        match = svc.attrs["matching"]?
        pidfile = svc.attrs["pidfile"]?
        if match && pidfile
          raise ParseError.new("'check process #{svc.name}' cannot have both 'matching' and 'pidfile'", svc.pos)
        end
        unless match || pidfile
          raise ParseError.new("'check process #{svc.name}' needs 'matching \"<pattern>\"' or 'with pidfile <path>'", svc.pos)
        end
        process = ProcessCheck.new(nil, match, pidfile, svc.tags.dup)
        process.every = every
        svc.rules.each do |rule|
          case rule.test
          when "not exist"
            process.policy = policy_for(svc, rule)
          when "cpu", "cpu usage", "total cpu", "total cpu usage"
            value = single_number(rule)
            unless value.unit == "%"
              raise ParseError.new("'#{rule.test}' needs a percentage, e.g. 'if #{rule.test} > 80%'", rule.pos)
            end
            process.rules << ProcessRule.new(rule.test.chomp(" usage"), comparison(rule), value.num.not_nil!, :percent, policy_for(svc, rule))
          when "memory", "memory usage", "total memory", "total memory usage"
            value = single_number(rule)
            unit = value.unit
            amount, kind = if unit == "%"
                             {value.num.not_nil!, :percent}
                           elsif unit && (mult = BYTE_UNITS[unit]?)
                             {value.num.not_nil! * mult, :bytes}
                           else
                             raise ParseError.new("'#{rule.test}' needs a percentage or a size (e.g. 10% or 500 MB), got #{value}", rule.pos)
                           end
            process.rules << ProcessRule.new(rule.test.chomp(" usage"), comparison(rule), amount, kind, policy_for(svc, rule))
          when "threads", "children"
            value = single_number(rule)
            raise ParseError.new("'#{rule.test}' needs a count, got #{value}", rule.pos) if value.unit
            process.rules << ProcessRule.new(rule.test, comparison(rule), value.num.not_nil!, :count, policy_for(svc, rule))
          when "uptime"
            process.rules << ProcessRule.new("uptime", comparison(rule), seconds(rule), :seconds, policy_for(svc, rule))
          when "disk read", "disk write", "total disk read", "total disk write",
               "disk read rate", "disk write rate", "total disk read rate", "total disk write rate"
            amount, kind = io_rate(rule)
            process.rules << ProcessRule.new(rule.test.chomp(" rate"), comparison(rule), amount, kind, policy_for(svc, rule))
          when "pid", "ppid"
            unless rule.op == Op::Changed
              raise ParseError.new("'#{rule.test}' can only be tested for change: 'if changed #{rule.test} then ...'", rule.pos)
            end
            process.rules << ProcessRule.new(rule.test, Op::Changed, policy: policy_for(svc, rule))
          when "failed port", "failed host"
            address = "localhost"
            args = rule.test_args
            if rule.test == "failed host"
              address = args.first? || raise ParseError.new("'failed host' needs an address and a port", rule.pos)
              args = args[1..]
              unless args.first?.try(&.downcase) == "port"
                raise ParseError.new("'failed host #{address}' needs 'port <n>'", rule.pos)
              end
              args = args[1..]
            end
            probe = port_probe(rule, args, address)
            process.rules << ProcessRule.new("port", Op::NE, probe.port.to_f64, :count, policy_for(svc, rule), probe)
          else
            unsupported_test(svc, rule)
          end
        end
        @processes[svc.name] = process
      end

      private def build_program(svc : Service, every : Int32)
        command = require_attr(svc, "path")
        timeout = svc.attrs["timeout"]?.try(&.to_i)
        rules = [] of ProgramRule
        svc.rules.each do |rule|
          case rule.test
          when "status", "exit status"
            op = rule.op
            v = rule.values.first?
            unless op && op != Op::Changed && v && (n = v.num) && v.unit.nil? && rule.values.size == 1
              raise ParseError.new("'status' needs a comparison with one exit code, e.g. 'if status != 0'", rule.pos)
            end
            rules << ProgramRule.new("status", op, number: n, policy: policy_for(svc, rule))
          when "content", "output"
            rules << ProgramRule.new("content", content_op(rule), pattern: regex(rule), policy: policy_for(svc, rule))
          else
            unsupported_test(svc, rule)
          end
        end
        prog = ProgramCheck.new(command, timeout, rules, svc.tags.dup)
        prog.every = every
        @programs[svc.name] = prog
      end

      private def build_host(svc : Service, every : Int32)
        address = require_attr(svc, "address")
        probes = [] of Tuple(PortProbe, Policy)
        svc.rules.each do |rule|
          if rule.test == "failed port"
            probes << {port_probe(rule, rule.test_args, address), policy_for(svc, rule)}
          else
            unsupported_test(svc, rule)
          end
        end
        warn(svc.pos, "'check host #{svc.name}' has no 'if failed port' rule; nothing will be checked") if probes.empty?
        # One result per rule: "web", or "web:443" with several ports, or
        # "web:443 (2)" when two rules test the same port.
        seen = Hash(Int32, Int32).new(0)
        probes.each do |probe, policy|
          seen[probe.port] += 1
          name = probes.size == 1 ? svc.name : "#{svc.name}:#{probe.port}"
          name += " (#{seen[probe.port]})" if seen[probe.port] > 1
          conn = ConnectionCheck.new(nil, address, probe.port, svc.tags.dup)
          conn.every = every
          conn.policy = policy
          conn.expect = probe.expect
          conn.probe = probe
          @connections[name] = conn
        end
      end

      private def build_network(svc : Service, every : Int32)
        iface = svc.attrs["interface"]?
        unless iface
          if svc.attrs["address"]?
            raise ParseError.new("'check network' by address is not supported yet, use 'with interface <name>'", svc.pos)
          end
          raise ParseError.new("'check network #{svc.name}' needs 'with interface <name>'", svc.pos)
        end
        net = InterfaceCheck.new(nil, iface, svc.tags.dup)
        net.every = every
        svc.rules.each do |rule|
          if rule.test == "link down" || rule.test == "failed link"
            net.policy = policy_for(svc, rule)
          else
            unsupported_test(svc, rule)
          end
        end
        @interfaces[svc.name] = net
      end

      private def build_bandwidth(svc : Service, every : Int32)
        address = require_attr(svc, "address")
        port = (svc.attrs["port"]? || "5201").to_i32
        limit = nil
        policy = Policy.new
        svc.rules.each do |rule|
          if rule.test == "bandwidth"
            unless rule.op == Op::LT || rule.op == Op::LE
              raise ParseError.new("bandwidth alerts when below a limit, use 'if bandwidth < <n> Mbps'", rule.pos)
            end
            v = rule.values.first
            n = v.num
            raise ParseError.new("bandwidth needs a number, got #{v}", rule.pos) unless n
            warn(rule.pos, "only one bandwidth limit is supported; using #{v}") if rule.values.size > 1
            limit = case v.unit
                    when nil, "mbps" then n
                    when "gbps"      then n * 1000
                    when "kbps"      then n / 1000
                    when "bps"       then n / 1_000_000
                    else
                      raise ParseError.new("bandwidth unit must be bps, kbps, Mbps or Gbps, got '#{v.unit}'", rule.pos)
                    end
            policy = policy_for(svc, rule)
          else
            unsupported_test(svc, rule)
          end
        end
        bw = BandwidthCheck.new(nil, address, port, limit, svc.tags.dup)
        bw.every = every
        bw.policy = policy
        @bandwidths[svc.name] = bw
      end

      # ---------------------------------------------------------------- policies

      # The cycle window and commands of a rule. restart/start/stop use the
      # service's start/stop programs.
      private def policy_for(svc : Service, rule : Rule) : Policy
        commands = commands_for(svc, rule.action, rule)
        recovery = rule.recovery.try { |a| commands_for(svc, a, rule) } || [] of String
        Policy.new(
          times: rule.times,
          cycles: rule.cycles,
          action: rule.action.kind.to_s.downcase,
          commands: commands,
          repeat: rule.action.repeat,
          recovery_commands: recovery
        )
      end

      private def commands_for(svc : Service, action : Action, rule : Rule) : Array(String)
        case action.kind
        when .alert?, .warn?
          [] of String
        when .exec?
          [action.command.not_nil!]
        when .start?
          [program(svc, rule, "start")]
        when .stop?
          [program(svc, rule, "stop")]
        when .restart?
          [program(svc, rule, "stop"), program(svc, rule, "start")]
        else # unmonitor
          warn(rule.pos, "'then unmonitor' is not supported yet; the rule will only alert")
          [] of String
        end
      end

      private def program(svc : Service, rule : Rule, which : String) : String
        cmd = which == "start" ? svc.start_program : svc.stop_program
        unless cmd
          raise ParseError.new("'then #{rule.action.kind.to_s.downcase}' needs '#{which} program = \"<command>\"' in 'check #{svc.type} #{svc.name}'", rule.pos)
        end
        cmd
      end

      # ---------------------------------------------------------------- helpers

      # The current threshold checks only implement "greater than".
      private def greater_than?(rule : Rule) : Bool
        case rule.op
        when Op::GT, Op::GE
          true
        else
          warn(rule.pos, "only '>' is supported for '#{rule.test}' at the moment; rule skipped")
          false
        end
      end

      private def thresholds(svc : Service, rule : Rule, percent_only : Bool = false) : Array(Threshold)
        policy = policy_for(svc, rule)
        rule.values.map do |v|
          n = v.num
          raise ParseError.new("'#{rule.test}' needs a number, got #{v}", rule.pos) unless n
          unit = v.unit
          if unit == "%"
            Threshold.new(n, :percent, policy)
          elsif !percent_only && unit && (mult = BYTE_UNITS[unit]?)
            Threshold.new(n * mult, :bytes, policy)
          elsif percent_only
            raise ParseError.new("'#{rule.test}' needs a percentage (e.g. 80%), got #{v}", rule.pos)
          else
            raise ParseError.new("'#{rule.test}' needs a percentage or a size (e.g. 80% or 5 GB), got #{v}", rule.pos)
          end
        end
      end

      # Sort levels (percentages first) and drop repeated levels, keeping the first rule.
      private def levels(list : Array(Threshold), svc : Service) : Array(Threshold)
        seen = Set(Tuple(Symbol, Float64)).new
        unique = list.select do |t|
          key = {t.unit, t.value}
          if seen.includes?(key)
            warn(svc.pos, "'#{svc.name}' has the level #{t.label} more than once; using the first rule")
            false
          else
            seen << key
            true
          end
        end
        unique.sort_by { |t| {t.unit == :percent ? 0 : 1, t.value} }
      end

      # <port> [type tcp|tcpssl] [protocol http|https] [request "/path"]
      # [hostheader "name"] [status <op> <code>] [content = "<regex>"]
      # [expect "<regex>"] [certificate valid <op> <n> days] [timeout <n> seconds]
      # [ssl options {verify: enable}]     (with/and/using are filler)
      private def port_probe(rule : Rule, args : Array(String), address : String) : PortProbe
        port = args.first?.try(&.to_i32?)
        raise ParseError.new("'#{rule.test}' needs a port number", rule.pos) unless port && 0 < port < 65536
        probe = PortProbe.new(address, port)
        rest = args[1..]
        take = ->(what : String) {
          rest.shift? || raise ParseError.new("expected #{what} at the end of '#{rule.test}'", rule.pos)
        }
        take_op = ->(what : String) {
          tok = take.call("a comparison after '#{what}'")
          Parser::OP_SYMBOLS[tok]? || Parser::OP_WORDS[tok.downcase]? ||
            raise ParseError.new("expected a comparison after '#{what}', got '#{tok}'", rule.pos)
        }
        take_regex = ->(what : String) {
          source = take.call("a pattern after '#{what}'")
          begin
            Regex.new(source)
          rescue ex : ArgumentError
            raise ParseError.new("invalid pattern #{source.inspect}: #{ex.message}", rule.pos)
          end
        }
        take_number = ->(what : String) {
          tok = take.call("a number after '#{what}'")
          tok.to_f64? || raise ParseError.new("expected a number after '#{what}', got '#{tok}'", rule.pos)
        }

        until rest.empty?
          key = rest.shift.downcase
          case key
          when "with", "and", "using", "use"
            next
          when "type"
            case value = take.call("tcp or tcpssl").downcase
            when "tcp"    then nil
            when "tcpssl" then probe.ssl = true
            else
              raise ParseError.new("only TCP ports are supported, got 'type #{value}'", rule.pos)
            end
          when "protocol"
            case value = take.call("a protocol").downcase
            when "http"  then probe.http = true
            when "https" then probe.http = probe.ssl = true
            else
              warn(rule.pos, "protocol tests ('protocol #{value}') are not supported yet; only the TCP connection is checked")
            end
          when "request"
            path = take.call("a path after 'request'")
            unless path.starts_with?('/')
              raise ParseError.new("'request' needs a path starting with '/', got '#{path}'", rule.pos)
            end
            probe.request = path
          when "hostheader"
            probe.host_header = take.call("a host name after 'hostheader'")
          when "status"
            probe.status_op = take_op.call("status")
            code = take_number.call("status")
            probe.status = code.to_i
          when "content"
            op = take_op.call("content")
            unless op.eq? || op.ne?
              raise ParseError.new("'content' needs '=' or '!=' and a pattern", rule.pos)
            end
            probe.content_op = op
            probe.content = take_regex.call("content")
          when "expect"
            probe.expect = take_regex.call("expect")
          when "certificate", "cert"
            unless rest.first?.try(&.downcase) == "valid"
              raise ParseError.new("expected 'certificate valid > <n> days'", rule.pos)
            end
            rest.shift
            probe.cert_op = take_op.call("certificate valid")
            probe.cert_days = take_number.call("certificate valid")
            rest.shift if rest.first?.try(&.downcase.in?("day", "days"))
          when "timeout"
            probe.timeout = take_number.call("timeout").to_i
            rest.shift if rest.first?.try(&.downcase.in?("s", "sec", "second", "seconds"))
          when "ssl"
            # ssl options {verify: enable, selfsigned: allow}
            rest.shift if rest.first?.try(&.downcase) == "options"
            opts = [] of String
            loop do
              tok = take.call("'}' to close the ssl options")
              opts << tok
              break if tok.ends_with?('}')
            end
            text = opts.join(" ").delete("{}").downcase
            text.scan(/([a-z]+)\s*:\s*([a-z0-9.]+)/) do |m|
              case {m[1], m[2]}
              when {"verify", "enable"}  then probe.verify = true
              when {"verify", "disable"} then probe.verify = false
              else
                warn(rule.pos, "ssl option '#{m[1]}: #{m[2]}' is not supported and was ignored")
              end
            end
            probe.ssl = true
          when "retry"
            take_number.call("retry")
            warn(rule.pos, "'retry' is not supported; use 'for N cycles' instead")
          else
            raise ParseError.new("unknown port option '#{key}', expected type, protocol, request, hostheader, " \
                                 "status, content, expect, certificate, timeout or ssl", rule.pos)
          end
        end

        if !probe.http && (probe.status_op || probe.content || probe.host_header || probe.request != "/")
          raise ParseError.new("request, hostheader, status and content need 'protocol http' or 'protocol https'", rule.pos)
        end
        if probe.http && probe.expect
          raise ParseError.new("'expect' checks a banner and can't be combined with 'protocol http'; use 'content'", rule.pos)
        end
        if probe.cert_op && !probe.ssl
          raise ParseError.new("'certificate valid' needs TLS: 'protocol https' or 'type tcpssl'", rule.pos)
        end
        probe
      end

      private def comparison(rule : Rule) : Op
        op = rule.op
        unless op && !op.changed?
          raise ParseError.new("'#{rule.test}' needs a comparison, e.g. 'if #{rule.test} > ...'", rule.pos)
        end
        op
      end

      private def single_number(rule : Rule) : Value
        v = rule.values.first?
        unless v && v.num && rule.values.size == 1
          raise ParseError.new("'#{rule.test}' needs one number", rule.pos)
        end
        v
      end

      SECONDS = {
        "s" => 1, "sec" => 1, "second" => 1, "seconds" => 1,
        "m" => 60, "min" => 60, "minute" => 60, "minutes" => 60,
        "h" => 3600, "hour" => 3600, "hours" => 3600,
        "d" => 86400, "day" => 86400, "days" => 86400,
      }

      private def seconds(rule : Rule) : Float64
        v = single_number(rule)
        mult = SECONDS[v.unit || "s"]? || raise ParseError.new("'#{rule.test}' needs a duration (s, min, hours, days), got #{v}", rule.pos)
        v.num.not_nil! * mult
      end

      RATE_PERIODS = {
        "s" => 1, "sec" => 1, "second" => 1,
        "m" => 60, "min" => 60, "minute" => 60,
        "h" => 3600, "hour" => 3600,
        "d" => 86400, "day" => 86400,
      }

      # 10 MB/s → {10485760.0, :bytes_rate};  500 operations/s → {500.0, :ops_rate}
      private def io_rate(rule : Rule) : Tuple(Float64, Symbol)
        v = single_number(rule)
        base, slash, period = (v.unit || "").partition('/')
        per = RATE_PERIODS[period]?
        if slash.empty? || per.nil?
          raise ParseError.new("'#{rule.test}' needs a rate, e.g. 10 MB/s or 500 operations/s, got #{v}", rule.pos)
        end
        if base.in?("operation", "operations", "ops", "op")
          {v.num.not_nil! / per, :ops_rate}
        elsif mult = BYTE_UNITS[base]?
          {v.num.not_nil! * mult / per, :bytes_rate}
        else
          raise ParseError.new("'#{rule.test}' needs bytes or operations per period, got #{v}", rule.pos)
        end
      end

      # failed [md5|sha1|sha256] checksum [and] [expect [the] [sum]] <hash>
      # Without a hash, the file is compared with its hash when Jane started.
      # Without an algorithm, it's inferred from the hash length (default md5).
      private def checksum_args(rule : Rule) : Tuple(String, String?)
        algorithm = rule.test == "failed checksum" ? nil : rule.test.split.last
        args = rule.test_args.map(&.downcase).reject(&.in?("checksum", "and", "expect", "sum"))
        raise ParseError.new("'#{rule.test}' takes one hash, got #{args.join(" ")}", rule.pos) if args.size > 1
        expect = args.first?
        if expect
          unless expect =~ /\A[0-9a-f]+\z/
            raise ParseError.new("checksum must be hexadecimal, got '#{expect}'", rule.pos)
          end
          inferred = CHECKSUM_ALGORITHMS.key_for?(expect.size)
          unless inferred
            raise ParseError.new("checksum has #{expect.size} digits; md5 has 32, sha1 40, sha256 64", rule.pos)
          end
          if algorithm && algorithm != inferred
            raise ParseError.new("a #{algorithm} checksum has #{CHECKSUM_ALGORITHMS[algorithm]} digits, got #{expect.size}", rule.pos)
          end
          algorithm = inferred
        end
        {algorithm || "md5", expect}
      end

      # A size: 2 GB, 500 kb, or a plain number of bytes.
      private def bytes(rule : Rule) : Float64
        v = single_number(rule)
        unit = v.unit
        return v.num.not_nil! if unit.nil? || unit == "b"
        mult = BYTE_UNITS[unit]? || raise ParseError.new("'#{rule.test}' needs a size (e.g. 500 MB), got #{v}", rule.pos)
        v.num.not_nil! * mult
      end

      private def content_op(rule : Rule) : Op
        op = rule.op
        unless op && (op.eq? || op.ne?)
          raise ParseError.new("'#{rule.test}' needs '=' or '!=' and a pattern, e.g. 'if #{rule.test} = \"error\"'", rule.pos)
        end
        op
      end

      private def regex(rule : Rule) : Regex
        v = rule.values.first?
        source = v.try(&.str) || v.try(&.to_s)
        raise ParseError.new("'#{rule.test}' needs a pattern", rule.pos) unless source
        warn(rule.pos, "only the first pattern is used for '#{rule.test}'") if rule.values.size > 1
        Regex.new(source)
      rescue ex : ArgumentError
        raise ParseError.new("invalid pattern #{source.inspect}: #{ex.message}", rule.pos)
      end

      private def single_arg(rule : Rule) : String
        arg = rule.test_args.first? || rule.values.first?.try(&.to_s)
        raise ParseError.new("'#{rule.test}' needs a value", rule.pos) unless arg
        arg
      end

      private def require_attr(svc : Service, attr : String) : String
        svc.attrs[attr]? || raise ParseError.new("'check #{svc.type} #{svc.name}' needs 'with #{attr} <value>'", svc.pos)
      end

      private def unsupported_test(svc : Service, rule : Rule)
        warn(rule.pos, "test '#{rule.test}' is not supported yet for 'check #{svc.type}'; rule skipped")
      end

      private def warn(pos : Pos, message : String)
        @warnings << {pos, message}
      end
    end

    # Parses a control file (following includes) and builds a Config.
    # Returns the config plus every warning collected along the way.
    def self.load(path : String) : Tuple(Config, Array(Tuple(Pos, String)))
      parser = Parser.parse_file(path)
      builder = Builder.new(parser.document, parser.warnings)
      {builder.build, builder.warnings}
    end
  end
end
