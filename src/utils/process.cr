require "colorize"
require "../monitor"
require "../config"
require "../logger"

## process.cr — checks whether specific processes are running

module Jane
  module ProcessChecker
    extend self


    def binary_running?(binary : String) : Bool
      status = Process.run("pgrep", {binary}, output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?
    rescue IO::Error
      # pgrep not found or failed to execute
      false
    end

    def check_process(name : String, proc_check : ProcessCheck) : Array(Monitor::Check)
      results = [] of Monitor::Check

      p proc_check


      if proc_check.bin && proc_check.match && proc_check.pidfile
        raise "Cannot have multiple process declarations"
      end

      if proc_check.match.nil? && proc_check.pidfile.nil? && proc_check.bin.nil?
        STDERR.puts "#{"⚠  Warning: check.process.#{name} has no 'match' or 'bin' or 'pidfile' defined, skipping".colorize(:yellow)}"
          #STDERR.puts
        return results
      end

      p proc_check.match

      if binary = proc_check.bin
      # check if proc is running by searching a binary-name
        found = binary_running?(binary)
        results << Monitor::Check.new(
          name: "Process #{name}",
          status: found ? :ok : :alert,
          current: found ? "running" : "not found",
          threshold: "running",
          message: found ? "Process '#{binary}' is running" : "Process '#{binary}' not found",
          description: proc_check.name
        )
        return results
      end

      if match = proc_check.match
        is_regex = match.includes?(".*") || match.includes?(".+") ||
                   match.includes?("\\d") || match.includes?("\\w") ||
                   match.includes?("[") || match.includes?("(") ||
                   match.includes?("{") || match.includes?("|") ||
                   match.includes?("^") || match.includes?("$") ||
                   match.ends_with?("+") || match.ends_with?("?")

        if is_regex
          pattern = Regex.new(match)
          found = scan_proc_cmdline { |cmdline| pattern.matches?(cmdline) }
        else
          found = scan_proc_cmdline { |cmdline| cmdline.includes?(match) }
        end

        results << Monitor::Check.new(
          name: "Process #{name}",
          status: found ? :ok : :alert,
          current: found ? "running" : "not found",
          threshold: "running",
          message: found ? "Process matching '#{match}' is running" : "Process matching '#{match}' not found",
          description: proc_check.name
        )
        return results
      end

      if pidfile = proc_check.pidfile
        found = check_pidfile(pidfile)
        results << Monitor::Check.new(
          name: "Process #{name}",
          status: found ? :ok : :alert,
          current: found ? "running" : "not found",
          threshold: "running",
          message: found ? "PID from '#{pidfile}' is running" : "PID from '#{pidfile}' not found or pidfile missing",
          description: proc_check.name
        )
        return results
      end
      return results
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

    # Scans /proc/<pid>/cmdline for all numeric PIDs and yields the
    # null-byte-joined command line. Returns true if the block ever returns true.
    private def scan_proc_cmdline(& : String -> Bool) : Bool
      Dir.each_child("/proc") do |entry|
        next unless entry.to_i?(strict: false)
        cmdline_path = "/proc/#{entry}/cmdline"
        next unless File.exists?(cmdline_path)
        begin
          raw = File.read(cmdline_path)
          cmdline = raw.gsub('\0', ' ').strip
          next if cmdline.empty?
          return true if yield cmdline
        rescue
          next
        end
      end
      false
    end

    # Reads a PID from a pidfile and checks if /proc/<pid> exists.
    private def check_pidfile(pidfile : String) : Bool
      return false unless File.exists?(pidfile)
      begin
        pid = File.read(pidfile).strip.to_i
        Dir.exists?("/proc/#{pid}")
      rescue
        false
      end
    end
  end
end
