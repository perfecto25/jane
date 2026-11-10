## proctable.cr — one /proc scan shared by every process check in a cycle
##
## Process resource tests (cpu, memory, threads, children, uptime) need data
## about the process and its descendants. Scanning /proc once per check would
## be wasteful with dozens of process checks, so a snapshot is reused for up
## to one second. CPU usage is the change in CPU time between two snapshots:
## in the daemon that is the previous cycle; on a first call (or `jane -s`) a
## second snapshot is taken 100 ms later.

module Jane
  module ProcTable
    extend self

    CLK_TCK   = LibC.sysconf(LibC::SC_CLK_TCK).to_i64 > 0 ? LibC.sysconf(LibC::SC_CLK_TCK).to_i64 : 100_i64
    PAGE_SIZE = LibC.sysconf(LibC::SC_PAGESIZE).to_i64 > 0 ? LibC.sysconf(LibC::SC_PAGESIZE).to_i64 : 4096_i64
    MAX_AGE   = 1.0 # seconds a snapshot is reused

    record Entry,
      pid : Int32,
      ppid : Int32,
      state : Char,
      jiffies : Int64,   # utime + stime
      threads : Int32,
      start_ticks : Int64, # starttime, in clock ticks since boot
      rss : Int64        # bytes

    class Snapshot
      getter taken_at : Float64 # system uptime in seconds (monotonic, same clock as start_ticks)
      getter entries : Hash(Int32, Entry)
      getter children : Hash(Int32, Array(Int32))

      def initialize(@taken_at, @entries)
        @children = Hash(Int32, Array(Int32)).new { |h, k| h[k] = [] of Int32 }
        @entries.each_value { |e| @children[e.ppid] << e.pid }
      end

      # The process and all of its descendants.
      def tree(pid : Int32) : Array(Int32)
        result = [] of Int32
        queue = [pid]
        while p = queue.shift?
          next unless @entries.has_key?(p)
          result << p
          queue.concat(@children.fetch(p, [] of Int32))
        end
        result
      end
    end

    @@current : Snapshot? = nil
    @@previous : Snapshot? = nil

    # Current snapshot, rescanning /proc if the last one is older than MAX_AGE.
    def snapshot : Snapshot
      if (cur = @@current) && uptime - cur.taken_at < MAX_AGE
        return cur
      end
      rescan
    end

    def rescan : Snapshot
      @@previous = @@current
      snap = scan
      @@current = snap
      snap
    end

    # CPU usage of `pids` as a percentage of the whole machine (100% = every
    # core busy), like Monit. Processes that started since the previous
    # snapshot are counted from 0.
    def cpu_percent(pids : Array(Int32)) : Float64
      cur = snapshot
      prev = @@previous
      if prev.nil? || cur.taken_at - prev.taken_at < 0.05
        sleep 100.milliseconds
        prev = cur
        cur = rescan
      end
      elapsed = cur.taken_at - prev.taken_at
      return 0.0 if elapsed <= 0

      used = pids.sum(0_i64) do |pid|
        now = cur.entries[pid]?
        next 0_i64 unless now
        before = prev.entries[pid]?
        base = before && before.start_ticks == now.start_ticks ? before.jiffies : 0_i64
        Math.max(now.jiffies - base, 0_i64)
      end
      (used.to_f64 / CLK_TCK) / (elapsed * System.cpu_count) * 100.0
    end

    # Seconds since the process started.
    def uptime_of(entry : Entry) : Float64
      Math.max(uptime - entry.start_ticks.to_f64 / CLK_TCK, 0.0)
    end

    def total_memory : Int64
      File.each_line("/proc/meminfo") do |line|
        if line.starts_with?("MemTotal:")
          return line.split[1].to_i64 * 1024
        end
      end
      0_i64
    end

    # Reads /proc/<pid>/stat. Returns nil if the process is gone.
    def read_entry(pid : Int32) : Entry?
      raw = File.read("/proc/#{pid}/stat")
      # comm (field 2) is in parentheses and may contain spaces.
      close = raw.rindex(')') || return nil
      f = raw[close + 2..].split(' ')
      Entry.new(
        pid: pid,
        ppid: f[1].to_i32,
        state: f[0][0],
        jiffies: f[11].to_i64 + f[12].to_i64,
        threads: f[17].to_i32,
        start_ticks: f[19].to_i64,
        rss: f[21].to_i64 * PAGE_SIZE
      )
    rescue File::Error | IndexError | ArgumentError
      nil
    end

    def uptime : Float64
      File.read("/proc/uptime").split.first.to_f64
    end

    # ---------------------------------------------------------------- disk I/O
    #
    # From /proc/<pid>/io: bytes actually read from / written to storage
    # (read_bytes, write_bytes; page-cache hits don't count) and the number of
    # read/write calls (syscr, syscw), used as "operations". Reading another
    # user's /proc/<pid>/io needs root (or the same user).

    record IOStat, read_bytes : Int64, write_bytes : Int64, reads : Int64, writes : Int64

    # Per-second rates summed over a set of processes.
    record IORate, read_bytes : Float64, write_bytes : Float64, reads : Float64, writes : Float64

    private record IOSample, taken_at : Float64, start_ticks : Int64, stat : IOStat

    # The last two samples per pid.
    @@io_samples = {} of Int32 => Array(IOSample)

    class IOAccessError < Exception
    end

    # Disk I/O rates of `pids`. Raises IOAccessError if /proc/<pid>/io can't be read.
    def io_rate(pids : Array(Int32)) : IORate
      prune_io_samples
      snap = snapshot
      live = pids.select { |p| snap.entries.has_key?(p) }

      needs_baseline = live.reject { |p| sample_io(p, snap.entries[p].start_ticks) }
      unless needs_baseline.empty?
        sleep 100.milliseconds
        needs_baseline.each { |p| sample_io(p, snap.entries[p].start_ticks, force: true) }
      end

      rb = wb = r = w = 0.0
      live.each do |pid|
        samples = @@io_samples[pid]?
        next unless samples && samples.size == 2
        a, b = samples[0], samples[1]
        elapsed = b.taken_at - a.taken_at
        next if elapsed <= 0
        rb += Math.max(b.stat.read_bytes - a.stat.read_bytes, 0_i64) / elapsed
        wb += Math.max(b.stat.write_bytes - a.stat.write_bytes, 0_i64) / elapsed
        r += Math.max(b.stat.reads - a.stat.reads, 0_i64) / elapsed
        w += Math.max(b.stat.writes - a.stat.writes, 0_i64) / elapsed
      end
      IORate.new(rb, wb, r, w)
    end

    def read_io(pid : Int32) : IOStat?
      values = {} of String => Int64
      File.each_line("/proc/#{pid}/io") do |line|
        key, _, value = line.partition(": ")
        values[key] = value.to_i64? || 0_i64
      end
      IOStat.new(values["read_bytes"]? || 0_i64, values["write_bytes"]? || 0_i64,
        values["syscr"]? || 0_i64, values["syscw"]? || 0_i64)
    rescue ex : File::AccessDeniedError
      raise IOAccessError.new("cannot read /proc/#{pid}/io (permission denied; run Jane as root or as the process owner)")
    rescue File::NotFoundError
      nil
    end

    # Adds a sample unless the newest one is less than MAX_AGE old (several
    # rules in one cycle share samples). Returns true when two samples exist.
    private def sample_io(pid : Int32, start_ticks : Int64, force : Bool = false) : Bool
      samples = @@io_samples[pid]?
      # A different start time means the pid was reused by a new process.
      samples = nil if samples && samples.last.start_ticks != start_ticks
      now = uptime
      if !force && samples && now - samples.last.taken_at < MAX_AGE
        return samples.size == 2
      end
      stat = read_io(pid)
      return false unless stat
      samples = (samples || [] of IOSample) + [IOSample.new(now, start_ticks, stat)]
      @@io_samples[pid] = samples.last(2)
      samples.size >= 2
    end

    # Drop samples of processes not sampled for 10 minutes.
    private def prune_io_samples
      now = uptime
      @@io_samples.reject! { |_, samples| now - samples.last.taken_at > 600 }
    end

    # Forget snapshots and samples (specs).
    def reset : Nil
      @@current = nil
      @@previous = nil
      @@io_samples.clear
    end

    private def scan : Snapshot
      taken_at = uptime
      entries = {} of Int32 => Entry
      Dir.each_child("/proc") do |name|
        pid = name.to_i32?
        next unless pid
        if entry = read_entry(pid)
          entries[pid] = entry
        end
      end
      Snapshot.new(taken_at, entries)
    end
  end
end
