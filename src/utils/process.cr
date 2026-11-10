require "colorize"
require "../monitor"
require "../config"
require "../logger"

## process.cr — checks whether specific processes are running

module Jane
  module ProcessChecker
    extend self


    # Last pid/ppid seen per check, for `if changed pid` / `if changed ppid`.
    @@last_ids = {} of String => Tuple(Int32, Int32)

    def check_process(name : String, proc_check : ProcessCheck, cycle : Int32 = 10) : Array(Monitor::Check)
      results = [] of Monitor::Check

      # The builder guarantees exactly one of `matching` / `pidfile`.
      pid, ok_msg, missing_msg =
        if match = proc_check.match
          {matching_pid(match), "Process matching '#{match}' is running", "Process matching '#{match}' not found"}
        else
          pidfile = proc_check.pidfile.not_nil!
          {pidfile_pid(pidfile), "PID from '#{pidfile}' is running", "PID from '#{pidfile}' not found or pidfile missing"}
        end

      results << Monitor::Check.new(
        name: "Process #{name}",
        status: pid ? :ok : :alert,
        current: pid ? "running" : "not found",
        threshold: "running",
        message: pid ? ok_msg : missing_msg,
        description: proc_check.name,
        policy: proc_check.policy
      )

      # Resource tests only make sense for a running process.
      if pid && !proc_check.rules.empty?
        if entry = ProcTable.snapshot.entries[pid]? || ProcTable.read_entry(pid)
          prev_ids = @@last_ids[name]?
          proc_check.rules.each do |rule|
            results << evaluate(name, rule, entry, prev_ids, cycle)
          end
          @@last_ids[name] = {entry.pid, entry.ppid}
        end
      end
      return results
    end

    private def evaluate(name : String, rule : ProcessRule, entry : ProcTable::Entry,
                         prev_ids : Tuple(Int32, Int32)?, cycle : Int32) : Monitor::Check
      check_name = "Process #{name} #{rule.label}"

      case rule.test
      when "pid", "ppid"
        now = rule.test == "pid" ? entry.pid : entry.ppid
        prev = prev_ids.try { |ids| rule.test == "pid" ? ids[0] : ids[1] }
        changed = !prev.nil? && prev != now
        return Monitor::Check.new(check_name, changed ? :alert : :ok, now.to_s, prev ? prev.to_s : "-",
          changed ? "#{rule.test.upcase} changed from #{prev} to #{now}" : "#{rule.test.upcase} unchanged",
          policy: rule.policy)
      when "port"
        probe = rule.probe || PortProbe.new("localhost", rule.value.to_i)
        r = Network::Connection.probe(probe, cycle - 1)
        return Monitor::Check.new(check_name, r.ok ? :ok : :alert, r.current, probe.http ? "#{probe.protocol_name} ok" : "open",
          r.message, policy: rule.policy)
      end

      tree = rule.test.starts_with?("total ") || rule.test == "children" ? ProcTable.snapshot.tree(entry.pid) : [entry.pid]
      value, current =
        case rule.test
        when "disk read", "disk write", "total disk read", "total disk write"
          rate = begin
            ProcTable.io_rate(tree)
          rescue ex : ProcTable::IOAccessError
            return Monitor::Check.new(check_name, :alert, "unknown", "#{Jane.op_symbol(rule.op)} #{rule.format_value}",
              ex.message.not_nil!, policy: rule.policy)
          end
          read = rule.test.ends_with?("read")
          if rule.unit == :ops_rate
            v = read ? rate.reads : rate.writes
            {v, "#{v.round(1)} ops/s"}
          else
            v = read ? rate.read_bytes : rate.write_bytes
            {v, "#{Threshold.new(v, :bytes).label}/s"}
          end
        when "cpu", "total cpu"
          pct = ProcTable.cpu_percent(tree)
          {pct, "%.2f%%" % pct}
        when "memory", "total memory"
          bytes = if rule.test == "memory"
                    entry.rss
                  else
                    snap = ProcTable.snapshot
                    tree.sum(0_i64) { |p| snap.entries[p]?.try(&.rss) || 0_i64 }
                  end
          if rule.unit == :percent
            total = ProcTable.total_memory
            pct = total > 0 ? bytes.to_f64 / total * 100 : 0.0
            {pct, "%.2f%%" % pct}
          else
            {bytes.to_f64, Threshold.new(bytes.to_f64, :bytes).label}
          end
        when "threads"
          {entry.threads.to_f64, entry.threads.to_s}
        when "children"
          n = tree.size - 1
          {n.to_f64, n.to_s}
        else # uptime
          up = ProcTable.uptime_of(entry)
          {up, Jane.format_duration(up)}
        end

      fired = Jane.compare(value, rule.op, rule.value)
      Monitor::Check.new(check_name, fired ? :alert : :ok, current, "#{Jane.op_symbol(rule.op)} #{rule.format_value}",
        fired ? "#{rule.test.capitalize} is #{current}" : "Within limits", policy: rule.policy)
    rescue ex : File::Error
      # The process exited between the snapshot and this read.
      Monitor::Check.new("Process #{name} #{rule.label}", :ok, "-", "", "Process exited during the check", policy: rule.policy)
    end

    # The oldest process (Monit picks the one with the highest uptime) whose
    # command line matches; Jane itself is excluded.
    private def matching_pid(match : String) : Int32?
      matchers = build_cmdline_matchers(match)
      own = Process.pid.to_i32
      pids = [] of Int32
      scan_proc_cmdline do |pid, cmdline|
        pids << pid if pid != own && matchers.any? { |m| m.call(cmdline) }
        false
      end
      return nil if pids.empty?
      return pids.first if pids.size == 1
      pids.min_by { |p| ProcTable.read_entry(p).try(&.start_ticks) || Int64::MAX }
    end

    private def pidfile_pid(pidfile : String) : Int32?
      return nil unless File.exists?(pidfile)
      pid = File.read(pidfile).strip.to_i32?
      pid && Dir.exists?("/proc/#{pid}") ? pid : nil
    rescue
      nil
    end

    private def process_running_by_name?(name : String) : Bool
      Dir.each_child("/proc") do |entry|
        next unless entry.each_char.all? { |ch| ch.ascii_number? }  # only numeric pids

        comm_path = "/proc/#{entry}/comm"
        begin
          # /proc/<pid>/comm contains the command name (truncated to 16 chars)
          comm = File.read(comm_path).strip
          return true if comm == name
        rescue ex : Errno
          # Process may have exited between listing /proc and reading comm; ignore
          next
        end
      end

      false
    end

    # Builds every interpretation of a `match` pattern: literal substring,
    # shell-style glob (* and ?), and regex. A cmdline that satisfies any of
    # them counts as a hit, so a config never has to declare which flavor it
    # meant — a proctitle like "sshd: ... [listener] ..." works as a literal
    # even though it also parses as a (non-matching) regex.
    private def build_cmdline_matchers(match : String) : Array(Proc(String, Bool))
      matchers = [] of Proc(String, Bool)

      matchers << ->(cmdline : String) { cmdline.includes?(match) }

      if match.includes?('*') || match.includes?('?')
        glob = Regex.new("^" + Regex.escape(match).gsub("\\*", ".*").gsub("\\?", ".") + "$")
        matchers << ->(cmdline : String) { glob.matches?(cmdline) }
      end

      begin
        pattern = Regex.new(match)
        matchers << ->(cmdline : String) { pattern.matches?(cmdline) }
      rescue ArgumentError
        # Not a valid regex (e.g. a leading '*' from a glob); other
        # interpretations still apply.
      end

      matchers
    end

    # Scans /proc/<pid>/cmdline for all numeric PIDs and yields the pid and
    # the null-byte-joined command line. Returns true if the block ever returns true.
    private def scan_proc_cmdline(& : Int32, String -> Bool) : Bool
      Dir.each_child("/proc") do |entry|
        pid = entry.to_i32?
        next unless pid
        cmdline_path = "/proc/#{entry}/cmdline"
        next unless File.exists?(cmdline_path)
        begin
          raw = File.read(cmdline_path)
          cmdline = raw.gsub('\0', ' ').strip
          next if cmdline.empty?
          return true if yield pid, cmdline
        rescue
          next
        end
      end
      false
    end

  end
end
