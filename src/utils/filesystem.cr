require "../info"
require "../monitor"
require "../config"
require "../rules/shell"

## all metrics, checks and anything related to Filesystems
##
## Usage comes from `stat -f`, run with a timeout: statvfs() on a hung NFS
## mount blocks forever, and must not freeze the daemon loop. Mount points are
## looked up in /proc/self/mounts, which doesn't touch the filesystem itself.

module Jane
  module Filesystem
    extend self

    struct MountEntry
      getter device : String
      getter mount_point : String
      getter fs_type : String
      getter options : String

      def initialize(@device : String, @mount_point : String, @fs_type : String, @options : String)
      end
    end

    # Space and inode numbers of one filesystem.
    record Usage,
      total : Int64, used : Int64, free : Int64, # bytes; free = available to non-root users
      inodes : Int64, inodes_free : Int64,       # 0 inodes: not reported (btrfs, ...)
      fs_type : String do
      def usage_pct : Float64
        total > 0 ? used.to_f64 / total * 100 : 0.0
      end

      def free_pct : Float64
        total > 0 ? free.to_f64 / total * 100 : 0.0
      end

      def inodes_used : Int64
        inodes - inodes_free
      end

      def inode_usage_pct : Float64
        inodes > 0 ? inodes_used.to_f64 / inodes * 100 : 0.0
      end
    end

    def mounts : Array(MountEntry)
      result = [] of MountEntry
      File.each_line("/proc/self/mounts") do |line|
        fields = line.split(' ')
        next if fields.size < 4
        result << MountEntry.new(unescape(fields[0]), unescape(fields[1]), fields[2], fields[3])
      end
      result
    end

    def show_filesystems
      mounts.each do |m|
        puts "#{m.device} mounted on #{m.mount_point} (#{m.fs_type})"
      end
    end # show_filesystems

    # The mount whose mount point or device is `path`. The last entry wins, as
    # a later mount hides an earlier one at the same place.
    def find_mount(path : String, entries : Array(MountEntry) = mounts) : MountEntry?
      norm = path == "/" ? "/" : path.rstrip('/')
      entries.reverse_each { |m| return m if m.mount_point == norm }
      entries.reverse_each { |m| return m if m.device == norm }
      # Symlinks: /dev/disk/by-uuid/..., a symlinked mount point
      real = File.realpath(norm) rescue nil
      if real && real != norm
        entries.reverse_each { |m| return m if m.mount_point == real || m.device == real }
      end
      nil
    end

    # Space and inodes of the filesystem containing `path`, via `stat -f`.
    # Returns the usage or an error message.
    def usage(path : String, timeout : Int32) : Usage | String
      cmd = "stat -f -c '%S %b %f %a %c %d %T' -- #{Process.quote(path)}"
      result = Shell.run(cmd, Math.max(timeout, 1).seconds)
      if result.timed_out
        return "'#{path}' did not respond within #{timeout}s (hung network mount?)"
      end
      unless result.success?
        return "cannot read '#{path}': #{result.output.strip.lines.last? || result.describe}"
      end
      f = result.output.split
      bsize, blocks, bfree, bavail, files, ffree = f[0, 6].map(&.to_i64)
      Usage.new(
        total: blocks * bsize,
        used: (blocks - bfree) * bsize,
        free: bavail * bsize,
        inodes: files,
        inodes_free: ffree,
        fs_type: f[6]? || "unknown"
      )
    rescue ex : IndexError | ArgumentError
      "unexpected 'stat -f' output for '#{path}'"
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

    # Mount options seen last cycle, for `if changed fsflags`.
    @@last_flags = {} of String => String

    # ---------- CHECKS
    def check_filesystem(name : String, fs_check : FilesystemCheck, cycle : Int32 = 10) : Array(Monitor::Check)
      results = [] of Monitor::Check
      path = fs_check.path

      # Like Monit, the path must be a mount point or a mounted device.
      mount = find_mount(path)
      unless mount
        message = File.exists?(path) ? "'#{path}' is not a mount point (nothing is mounted there)" : "'#{path}' not found"
        return [failure(name, File.exists?(path) ? "not mounted" : "missing", message)]
      end

      usage = usage(mount.mount_point, cycle - 1)
      return [failure(name, "error", usage)] if usage.is_a?(String)

      levels = fs_check.usage.select { |t| t.unit == :bytes || t.unit == :percent }
      levels.each do |threshold|
        if threshold.unit == :bytes
          status = usage.used > threshold.to_bytes ? :alert : :ok
          current = format_bytes(usage.used)
          limit = threshold.format_value
        else
          status = usage.usage_pct > threshold.to_percent ? :alert : :ok
          current = "%.2f%%" % usage.usage_pct
          limit = "%.2f%%" % threshold.to_percent
        end
        results << Monitor.level_check("Filesystem #{name}", threshold, levels,
          status, current, limit,
          status == :alert ? "Filesystem usage exceeds limit" : "Within limits")
      end

      fs_check.rules.each do |rule|
        results << evaluate(name, rule, usage, mount)
      end
      return results
    end # check_filesystem

    private def evaluate(name : String, rule : FilesystemRule, usage : Usage, mount : MountEntry) : Monitor::Check
      check_name = "Filesystem #{name} #{rule.label}"

      if rule.test == "fsflags"
        flags = mount.options
        prev = @@last_flags[name]?
        @@last_flags[name] = flags
        changed = !prev.nil? && prev != flags
        mode = flags.split(',').find(&.in?("rw", "ro")) || flags.split(',').first
        return Monitor::Check.new(check_name, changed ? :alert : :ok, mode, "unchanged",
          changed ? "Mount options changed from '#{prev}' to '#{flags}'" : "Mount options unchanged (#{flags.size > 60 ? flags[0, 60] + "…" : flags})",
          policy: rule.policy)
      end

      if rule.test.starts_with?("inode") && usage.inodes == 0
        return Monitor::Check.new(check_name, :ok, "n/a", "", "#{usage.fs_type} doesn't report inode counts", policy: rule.policy)
      end

      value, current =
        case {rule.test, rule.unit}
        when {"space free", :percent} then {usage.free_pct, "%.2f%%" % usage.free_pct}
        when {"space free", _}        then {usage.free.to_f64, format_bytes(usage.free)}
        when {"inode usage", :percent} then {usage.inode_usage_pct, "%.2f%%" % usage.inode_usage_pct}
        when {"inode usage", _}        then {usage.inodes_used.to_f64, usage.inodes_used.to_s}
        when {"inode free", :percent}  then {100.0 - usage.inode_usage_pct, "%.2f%%" % (100.0 - usage.inode_usage_pct)}
        else                                {usage.inodes_free.to_f64, usage.inodes_free.to_s}
        end
      fired = Jane.compare(value, rule.op, rule.value)
      threshold = rule.label.sub(rule.test, "").strip
      Monitor::Check.new(check_name, fired ? :alert : :ok, current, threshold,
        fired ? "#{rule.test.capitalize} is #{current}" : "Within limits", policy: rule.policy)
    end

    private def failure(name : String, current : String, message : String) : Monitor::Check
      Monitor::Check.new("Filesystem #{name}", :alert, current, "mounted", message)
    end

    # /proc/self/mounts escapes space, tab, newline and backslash as octal.
    private def unescape(field : String) : String
      field.gsub(/\\([0-7]{3})/) { |_, m| m[1].to_i(8).chr.to_s }
    end
  end # Filesystem
end # Jane
