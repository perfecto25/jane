require "tallboy"
require "colorize"
require "io"
require "./utils/*"
require "./state"

## monitor.cr — core monitoring structures and orchestration

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

      def initialize(@name, status : Symbol, @current, @threshold, @message, @tags = [] of String, @description = nil)
        @status = status.to_s
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
    def self.perform_checks(config : Config) : Array(Check)
      results = [] of Check
      checks = config.check

      # --- CPU ---
      if cpu_check = checks.cpu
        cpu_results = Cpu.check_cpu(cpu_check)
        cpu_results.each { |c| c.tags.concat(cpu_check.tags) }
        results.concat cpu_results
      end

      # --- Memory ---
      if mem_check = checks.memory
        mem_results = Memory.check_memory(mem_check)
        mem_results.each { |c| c.tags.concat(mem_check.tags) }
        results.concat mem_results
      end

      # --- Filesystems ---
      checks.filesystems.each do |name, fs_check|
        fs_results = Filesystem.check_filesystem(name, fs_check)
        fs_results.each { |c| c.tags.concat(fs_check.tags) }
        results.concat fs_results
      end

      # --- Network: Interfaces ---
      checks.network_interfaces.each do |name, iface_check|
        iface_results = Network::Interface.check_iface(name, iface_check)
        iface_results.each { |c| c.tags.concat(iface_check.tags) }
        results.concat iface_results
      end

      # --- Network: Connections ---
      checks.network_connections.each do |name, conn_check|
        conn_results = Network::Connection.check_connection(name, conn_check, config.defaults.cycle - 1)
        conn_results.each { |c| c.tags.concat(conn_check.tags) }
        results.concat conn_results
      end

      # --- Network: Bandwidth ---
      checks.network_bandwidths.each do |name, bw_check|
        bw_results = Network::Bandwidth.check_bandwidth(name, bw_check, config.defaults.cycle - 1)
        bw_results.each { |c| c.tags.concat(bw_check.tags) }
        results.concat bw_results
      end

      # --- Processes ---
      checks.processes.each do |name, proc_check|
        proc_results = ProcessChecker.check_process(name, proc_check)
        proc_results.each { |c| c.tags.concat(proc_check.tags) }
        results.concat proc_results
      end

      # --- Files ---
      checks.files.each do |name, file_check|
        file_results = FileChecker.check_file(name, file_check)
        file_results.each { |c| c.tags.concat(file_check.tags) }
        results.concat file_results
      end

      return results
    end # perform_checks


    

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

    # ------------------------------------------------------------------
    # display_status — runs checks and prints a table to stdout
    # ------------------------------------------------------------------
    def self.display_status(config : Config, config_path : String = "config.toml")
      results = perform_checks(config)
      unmonitored_tags = State.unmonitored_tags(config_path)

      monitored = results.reject { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }
      unmonitored = results.select { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }

      sorted = monitored.sort_by { |c| c.alert? ? 0 : 1 }

      table = Tallboy.table do
        header ["Check", "Status", "Current", "Threshold", "Message", "Tags"]
        sorted.each do |check|
          tags_str = check.tags.empty? ? "" : check.tags.join(", ")
          msg_parts = Jane::Monitor.wrap_message(check.message)

          # Plain text only inside cells — ANSI codes inflate Tallboy's column
          # width calculation and misalign borders. Colors are post-processed.
          # border: :bottom goes on the last row of each check so continuation
          # rows are grouped together without a separator between them.
          last = msg_parts.size - 1
          row [check.name, check.status, check.current, check.threshold, msg_parts[0], tags_str],
            border: last == 0 ? Tallboy::Border::Bottom : Tallboy::Border::None
          msg_parts[1..].each_with_index do |part, i|
            row ["", "", "", "", part, ""], border: i == last - 1 ? Tallboy::Border::Bottom : Tallboy::Border::None
          end
        end
      end

      # Post-process the rendered table to apply colors:
      #   • border/separator lines  → white
      #   • │ column dividers       → white
      #   • alert row content       → red  (carried through continuation rows)
      #   • ok row content          → default
      in_alert = false
      table.render.to_s.split('\n').each do |line|
        if line.starts_with?("│")
          parts = line.split("│")
          status    = parts[2]?.try(&.strip) || ""
          check_col = parts[1]?.try(&.strip) || ""
          if status == "alert"
            in_alert = true
          elsif status == "ok" || status == "Status"
            in_alert = false
          elsif check_col.empty? && status.empty?
            # continuation row — preserve current in_alert state
          else
            in_alert = false
          end
          # Rebuild line: │ borders white, cell content red (alert) or default
          colored = parts.map_with_index do |seg, i|
            i == 0 ? seg : "│".to_s + (in_alert ? seg.colorize(:light_red).to_s : seg)
          end.join("")
          puts colored
        else
          # Separator / border line (├, ┌, └ …) — color white; don't touch in_alert
          puts line.empty? ? line : line.to_s
        end
      end

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

    # Filters results to only those in alert state
    def self.alerts(results : Array(Check)) : Array(Check)
      results.select(&.alert?)
    end

  end # Monitor
end # Jane
