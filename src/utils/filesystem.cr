require "../info"
require "../monitor"
require "../config"

## all metrics, checks and anything related to Filesystems

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

    def show_filesystems

      mounts = [] of MountEntry

      File.each_line("/proc/self/mounts") do |line|
        fields = line.split(' ')
        next if fields.size < 4

        device = fields[0].gsub("\\040", " ")
        mount_point = fields[1].gsub("\\040", " ")
        fs_type = fields[2]
        options = fields[3]

        mounts << MountEntry.new(device, mount_point, fs_type, options)
      end

      mounts.each do |m|
        puts "#{m.device} mounted on #{m.mount_point} (#{m.fs_type})"
      end
    end # show_filesystems

    private def get_filesystem_usage(path : String) : Hash(Symbol, Int64 | Float64)?
      output = `df -B1 #{path} 2>/dev/null`.lines
      return nil if output.size < 2

      parts = output[1].split
      total = parts[1].to_i64
      used = parts[2].to_i64

      result = Hash(Symbol, Int64 | Float64).new
      result[:total] = total
      result[:used] = used
      result[:available] = parts[3].to_i64
      result[:usage_pct] = (used.to_f64 / total.to_f64) * 100.0
      return result
    rescue
      nil
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

    # ---------- CHECKS
    def check_filesystem(name : String, fs_check : FilesystemCheck) : Array(Monitor::Check)
      results = [] of Monitor::Check

      usage = get_filesystem_usage(fs_check.path)
      return results unless usage

      fs_check.usage.each do |threshold|
        used_bytes = usage[:used].as(Int64)
        total_bytes = usage[:total].as(Int64)
        usage_pct = usage[:usage_pct].as(Float64)

        case threshold.unit
        when :bytes
          limit_bytes = threshold.to_bytes
          status = used_bytes > limit_bytes ? :alert : :ok
          msg = status == :alert ? "Filesystem usage exceeds limit" : "Within limits"
          results << Monitor::Check.new(
            "Filesystem #{name}",
            status,
            format_bytes(used_bytes),
            threshold.format_value,
            msg
          )
          break
        when :percent
          limit_pct = threshold.to_percent
          status = usage_pct > limit_pct ? :alert : :ok
          msg = status == :alert ? "Filesystem usage exceeds limit" : "Within limits"
          results << Monitor::Check.new(
            "Filesystem #{name}",
            status,
            "%.2f%%" % usage_pct,
            "%.2f%%" % limit_pct,
            msg
          )
          break
        end
      end
      return results
    end # check_filesystem

  end # Filesystem
end # Jane
