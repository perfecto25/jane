require "tallboy"
require "colorize"
require "io"
require "./utils/*"
require "./state"
require "./rules/scheduler"
require "./rules/engine"
require "./logger"

## monitor.cr — core monitoring structures and orchestration

# Terminal size of stdout (Linux).
lib LibTerm
  struct Winsize
    ws_row : UInt16
    ws_col : UInt16
    ws_xpixel : UInt16
    ws_ypixel : UInt16
  end

  TIOCGWINSZ = 0x5413_u64
  fun ioctl(fd : LibC::Int, request : LibC::ULong, ws : Winsize*) : LibC::Int
end

module Jane
  module Monitor

    # Represents the result of a single check
    class Check
      include JSON::Serializable

      getter name : String
      getter status : String         # "ok" or "alert"
      getter current : String        # current measured value
      getter threshold : String      # configured threshold / expected value
      getter message : String        # human-readable explanation
      getter tags : Array(String)
      getter description : String?

      # How the Engine turns this result into alerts and actions. Not sent to HQ.
      @[JSON::Field(ignore: true)]
      property policy : Policy = Policy.new

      # Threshold levels (`> 80, 90, 95 %`): each level is its own result for
      # the Engine (own window and actions), and `collapse_levels` merges the
      # levels sharing a group into one row. `level` ranks them, 0 = lowest.
      @[JSON::Field(ignore: true)]
      property group : String? = nil
      @[JSON::Field(ignore: true)]
      property group_name : String? = nil
      @[JSON::Field(ignore: true)]
      property level : Int32 = 0

      def initialize(@name, status : Symbol, @current, @threshold, @message, @tags = [] of String, @description = nil, @policy = Policy.new)
        @status = status.to_s
      end

      # Copy with a different status and message (used by the Engine).
      def with_status(status : Symbol, message : String) : Check
        copy(@name, status, message)
      end

      # Copy with another name (used by collapse_levels).
      def renamed(name : String) : Check
        copy(name, @status == "alert" ? :alert : :ok, @message)
      end

      private def copy(name : String, status : Symbol, message : String) : Check
        c = Check.new(name, status, @current, @threshold, message, @tags.dup, @description, @policy)
        c.group = @group
        c.group_name = @group_name
        c.level = @level
        c
      end

      def alert? : Bool
        @status == "alert"
      end

      def ok? : Bool
        @status == "ok"
      end

      def to_s : String
        icon = alert? ? "✖" : "✔"
        "[#{icon}] #{@name}: #{@message} (current: #{@current}, threshold: #{@threshold})"
      end
    end # Check

    # ------------------------------------------------------------------
    # perform_checks — iterates through all configured checks and
    # collects Monitor::Check results. Each module follows the same
    # contract:  def check_*(config) : Array(Monitor::Check)
    # ------------------------------------------------------------------
    #
    # With a Scheduler (daemon mode), checks with `every N` only run every Nth
    # cycle; otherwise every check runs.
    def self.perform_checks(config : Config, scheduler : Scheduler? = nil) : Array(Check)
      results = [] of Check
      checks = config.check

      if cpu_check = checks.cpu
        results.concat scheduled(scheduler, "cpu", cpu_check.every, cpu_check.tags) { Cpu.check_cpu(cpu_check) }
      end

      if mem_check = checks.memory
        results.concat scheduled(scheduler, "memory", mem_check.every, mem_check.tags) { Memory.check_memory(mem_check) }
      end

      checks.filesystems.each do |name, fs_check|
        results.concat scheduled(scheduler, "filesystem:#{name}", fs_check.every, fs_check.tags) {
          Filesystem.check_filesystem(name, fs_check, config.defaults.cycle)
        }
      end

      checks.network_interfaces.each do |name, iface_check|
        results.concat scheduled(scheduler, "interface:#{name}", iface_check.every, iface_check.tags, iface_check.policy) {
          Network::Interface.check_iface(name, iface_check)
        }
      end

      checks.network_connections.each do |name, conn_check|
        results.concat scheduled(scheduler, "connection:#{name}", conn_check.every, conn_check.tags, conn_check.policy) {
          Network::Connection.check_connection(name, conn_check, config.defaults.cycle - 1)
        }
      end

      checks.network_bandwidths.each do |name, bw_check|
        results.concat scheduled(scheduler, "bandwidth:#{name}", bw_check.every, bw_check.tags, bw_check.policy) {
          Network::Bandwidth.check_bandwidth(name, bw_check, config.defaults.cycle - 1)
        }
      end

      checks.processes.each do |name, proc_check|
        # The process check sets policies itself: existence vs. each resource rule.
        results.concat scheduled(scheduler, "process:#{name}", proc_check.every, proc_check.tags) {
          ProcessChecker.check_process(name, proc_check, config.defaults.cycle)
        }
      end

      checks.files.each do |name, file_check|
        results.concat scheduled(scheduler, "file:#{name}", file_check.every, file_check.tags) {
          FileChecker.check_file(name, file_check)
        }
      end

      checks.programs.each do |name, prog_check|
        results.concat scheduled(scheduler, "program:#{name}", prog_check.every, prog_check.tags) {
          ProgramChecker.check_program(name, prog_check, config.defaults.cycle)
        }
      end

      return results
    end # perform_checks




    # Runs one check (through the scheduler when there is one) and stamps its
    # results with the check's tags. `policy` is only for checks that produce a
    # single result; checks with several results set their policies themselves.
    private def self.scheduled(scheduler : Scheduler?, key : String, every : Int32, tags : Array(String),
                               policy : Policy? = nil, &block : -> Array(Check)) : Array(Check)
      run = -> {
        results = block.call
        results.each do |c|
          c.tags.concat(tags)
          c.policy = policy if policy
        end
        results
      }
      scheduler ? scheduler.run(key, every) { run.call } : run.call
    end

    # Collapses newlines and splits a string into chunks of at most `width`
    # characters, breaking at word boundaries where possible.
    def self.wrap_message(msg : String, width : Int32 = 80) : Array(String)
      flat = msg.gsub('\n', ' ').gsub('\r', ' ').squeeze(' ').strip
      return [flat] if flat.size <= width
      chunks = [] of String
      remaining = flat
      while remaining.size > width
        slice = remaining[0, width]
        if (break_pos = slice.rindex(' '))
          chunks << remaining[0, break_pos]
          remaining = remaining[break_pos + 1..]
        else
          chunks << slice
          remaining = remaining[width..]
        end
      end
      chunks << remaining unless remaining.empty?
      chunks
    end

    STATUS_HEADERS = ["Check", "Status", "Current", "Threshold", "Message", "Tags"]
    # Narrowest each column gets when the terminal is small. Status, Current
    # and Threshold are short and only shrink as a last resort.
    STATUS_MIN_WIDTHS = [14, 6, 8, 9, 16, 6]

    # Terminal width: the window size of stdout, else $COLUMNS. Nil when
    # neither is known (output piped to a file): no limit then.
    def self.terminal_width : Int32?
      if STDOUT.tty?
        ws = LibTerm::Winsize.new
        if LibTerm.ioctl(STDOUT.fd, LibTerm::TIOCGWINSZ, pointerof(ws)) == 0 && ws.ws_col > 0
          return ws.ws_col.to_i32
        end
      end
      ENV["COLUMNS"]?.try(&.to_i?).try { |c| c > 0 ? c : nil }
    end

    # Column widths that fit `max_width` (including borders and padding),
    # shrinking the wrappable columns first. Nil max_width: natural widths.
    def self.fit_widths(rows : Array(Array(String)), max_width : Int32?) : Array(Int32)
      widths = STATUS_HEADERS.map_with_index { |h, i| rows.max_of?(&.[i].size).try { |w| Math.max(w, h.size) } || h.size }
      return widths unless max_width
      overhead = widths.size * 3 + 1 # "│ " + " " per column, plus the last "│"
      excess = widths.sum + overhead - max_width
      floor = ->(i : Int32) { Math.min(widths[i], STATUS_MIN_WIDTHS[i]) }
      shave = ->(i : Int32, n : Int32) do
        cut = Math.min(n, widths[i] - floor.call(i))
        widths[i] -= cut
        excess -= cut
      end

      # 1. Tags down to 10.  2. Message and Check, one character at a time
      # from whichever is wider.  3. Tags, Threshold, Current to their minimum.
      shave.call(5, Math.min(excess, widths[5] - Math.max(10, floor.call(5)))) if excess > 0 && widths[5] > 10
      while excess > 0
        i = widths[4] >= widths[0] ? 4 : 0
        i = i == 4 ? 0 : 4 if widths[i] <= floor.call(i)
        break if widths[i] <= floor.call(i)
        shave.call(i, 1)
      end
      [5, 3, 2].each { |i| shave.call(i, excess) if excess > 0 }
      widths
    end

    # Prints the results as a table that fits the terminal. Cells too wide for
    # their column wrap onto continuation lines; a separator then goes after
    # each check. When nothing wraps, rows are printed without separators.
    def self.print_status_table(checks : Array(Check), max_width : Int32? = terminal_width)
      rows = checks.map do |c|
        [c.name, c.status, c.current, c.threshold, c.message.gsub(/\s+/, " ").strip, c.tags.join(", ")]
      end
      widths = fit_widths(rows, max_width)
      wrapped = rows.map { |r| r.map_with_index { |cell, i| cell.empty? ? [""] : wrap_message(cell, widths[i]) } }
      multi_line = wrapped.any? { |cells| cells.any? { |lines| lines.size > 1 } }

      table = Tallboy.table do
        # Plain text only inside cells — ANSI codes inflate Tallboy's column
        # width calculation and misalign borders. Colors are post-processed.
        header STATUS_HEADERS
        wrapped.each_with_index do |cells, n|
          height = cells.max_of(&.size)
          height.times do |line|
            last = line == height - 1 && n < wrapped.size - 1
            row cells.map { |lines| lines[line]? || "" },
              border: last && multi_line ? Tallboy::Border::Bottom : Tallboy::Border::None
          end
        end
      end

      # Color alert rows red. A line with an empty Status cell continues the
      # check above it and keeps its color.
      in_alert = false
      table.render.to_s.split('\n').each do |line|
        if line.starts_with?("│")
          parts = line.split("│")
          status = parts[2]?.try(&.strip) || ""
          in_alert = status == "alert" unless status.empty?
          puts parts.map_with_index { |seg, i| i == 0 ? seg : "│" + (in_alert ? seg.colorize(:light_red).to_s : seg) }.join
        else
          puts line
        end
      end
    end

    # ------------------------------------------------------------------
    # display_status — runs checks and prints a table to stdout
    # ------------------------------------------------------------------
    def self.display_status(config : Config, config_path : String = DEFAULT_CONFIG)
      results = collapse_levels(perform_checks(config))
      unmonitored_tags = State.unmonitored_tags(config_path)

      monitored = results.reject { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }
      unmonitored = results.select { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }

      sorted = monitored.sort_by { |c| c.alert? ? 0 : 1 }
      print_status_table(sorted)

      alerts = monitored.select(&.alert?)
      if alerts.any?
        puts "\n#{"⚠  #{alerts.size} alert(s) detected".colorize(:yellow).bold}"
      else
        puts "\n✔  All checks passed"
      end

      if unmonitored.any?
        puts "\n#{"Unmonitored Services".colorize(:dark_gray)}"
        seen = Set(String).new
        unmon_table = Tallboy.table do
          header ["Check", "Tags"]
          unmonitored.each do |check|
            next if seen.includes?(check.name)
            seen.add(check.name)
            row [check.name, check.tags.join(", ")]
          end
        end
        puts unmon_table.render
      end
    end

    # Name for one threshold level of a check. A single level keeps the plain
    # name ("Memory Usage"); several levels are told apart: "Memory Usage >90%".
    # These names are internal (Engine state); collapse_levels shows `base`.
    def self.level_name(base : String, threshold : Threshold, levels : Array(Threshold)) : String
      levels.size > 1 ? "#{base} >#{threshold.label}" : base
    end

    # A result for one threshold level, grouped with its sibling levels.
    # Levels in different units (`> 90%` and `> 30 GB`) form separate groups.
    def self.level_check(base : String, threshold : Threshold, levels : Array(Threshold),
                         status : Symbol, current : String, limit : String, message : String) : Check
      check = Check.new(level_name(base, threshold, levels), status, current, limit, message, policy: threshold.policy)
      if levels.size > 1
        same_unit = levels.select { |t| t.unit == threshold.unit }
        mixed = same_unit.size < levels.size
        check.group = "#{base}\0#{threshold.unit}"
        check.group_name = mixed ? "#{base} (#{threshold.unit == :percent ? "%" : "size"})" : base
        check.level = same_unit.count { |t| t.value < threshold.value }
      end
      check
    end

    # One row per multi-level check: the highest level in alert, or, when no
    # level alerts, the lowest level (the next one to trip). Rows keep the
    # position of the group's first level.
    def self.collapse_levels(results : Array(Check)) : Array(Check)
      groups = {} of String => Array(Check)
      results.each { |c| (groups[c.group.not_nil!] ||= [] of Check) << c if c.group }
      return results if groups.empty?

      out = [] of Check
      results.each do |c|
        if group = c.group
          members = groups.delete(group)
          next unless members # already emitted
          chosen = members.select(&.alert?).max_by?(&.level) || members.min_by(&.level)
          out << chosen.renamed(chosen.group_name || chosen.name)
        else
          out << c
        end
      end
      out
    end

    # Filters results to only those in alert state
    def self.alerts(results : Array(Check)) : Array(Check)
      results.select(&.alert?)
    end

  end # Monitor
end # Jane
