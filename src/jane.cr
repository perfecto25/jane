require "option_parser"
require "./config"
require "./info"
require "./monitor"
require "./daemon"
require "./logger"
require "./state"
require "./alert"

module Jane
  {% begin %}
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}

  class CLI
    def self.run
      mode = :info
      config_path = "config.toml"

      # Check for positional subcommands before option parsing
      if ARGV.size >= 2 && (ARGV[0] == "unmonitor" || ARGV[0] == "monitor")
        subcommand = ARGV[0]
        tag = ARGV[1]
        # Allow -c flag after subcommand args
        config_path_idx = ARGV.index("-c") || ARGV.index("--config")
        if config_path_idx && config_path_idx + 1 < ARGV.size
          config_path = ARGV[config_path_idx + 1]
        end

        config = Config.from_file(config_path)

        case subcommand
        when "unmonitor"
          handle_unmonitor(config, config_path, tag)
        when "monitor"
          handle_monitor(config, config_path, tag)
        end
        return
      end

      OptionParser.parse do |parser|
        parser.banner = "Usage: jane [options]"

        parser.on("-i", "--info", "Show system information") { mode = :info }
        parser.on("-s", "--status", "Show system status vs config") { mode = :status }
        parser.on("-d", "--daemon", "Run as daemon") { mode = :daemon }
        parser.on("-c FILE", "--config=FILE", "Config file path (default: config.toml)") { |f| config_path = f }
        parser.on("-h", "--help", "Show help") { mode = :help }
        parser.on("-v", "--version", "Show version") do
          puts "Jane Agent v#{VERSION}"
          exit 0
        end
      end

      case mode
      when :info
        Info.display
      when :status
        config = Config.from_file(config_path)
        Monitor.display_status(config, config_path)
      when :daemon
        config = Config.from_file(config_path)
        Daemon.run(config, config_path)
      when :help
        puts "Usage: jane [options]"
        puts "  -i, --info              Show system information"
        puts "  -s, --status            Show system status vs config"
        puts "  -d, --daemon            Run as daemon"
        puts "  -c, --config FILE       Config file path (default: config.toml)"
        puts "  -h, --help              Show help"
        puts "  -v, --version           Show version"
        puts ""
        puts "Subcommands:"
        puts "  unmonitor <tag>         Unmonitor all checks with the given tag"
        puts "  monitor <tag>           Re-monitor all checks with the given tag"
      end
    end

    def self.handle_unmonitor(config : Config, config_path : String, tag_arg : String)
      input_tags = tag_arg.split(",").map(&.strip).reject(&.empty?)
      unmonitored = State.unmonitored_tags(config_path)
      all_matching = [] of String
      added_tags = [] of String

      input_tags.each do |tag|
        matching = find_checks_with_tag(config, tag)
        if matching.empty?
          puts "No checks found with tag '#{tag}'"
          next
        end
        all_matching.concat(matching)
        unless unmonitored.includes?(tag)
          unmonitored << tag
          added_tags << tag
        end
      end

      return if all_matching.empty?

      State.save(config_path, unmonitored) unless added_tags.empty?

      puts "These services will be unmonitored:"
      all_matching.uniq.each { |name| puts "  - #{name}" }
      puts "\nTo monitor them again, run: jane monitor #{input_tags.join(",")}"
    end

    def self.handle_monitor(config : Config, config_path : String, tag_arg : String)
      input_tags = tag_arg.split(",").map(&.strip).reject(&.empty?)
      unmonitored = State.unmonitored_tags(config_path)
      all_matching = [] of String
      removed_any = false

      input_tags.each do |tag|
        unless unmonitored.includes?(tag)
          puts "Tag '#{tag}' is already monitored"
          next
        end
        all_matching.concat(find_checks_with_tag(config, tag))
        unmonitored.delete(tag)
        removed_any = true
      end

      if removed_any
        State.save(config_path, unmonitored)
        puts "These services are now monitored:"
        all_matching.uniq.each { |name| puts "  - #{name}" }
      end
    end

    def self.find_checks_with_tag(config : Config, tag : String) : Array(String)
      names = [] of String
      checks = config.check

      if cpu = checks.cpu
        names << "CPU" if cpu.tags.includes?(tag)
      end
      if mem = checks.memory
        names << "Memory" if mem.tags.includes?(tag)
      end
      checks.filesystems.each do |name, fs|
        names << "Filesystem #{name}" if fs.tags.includes?(tag)
      end
      checks.network_interfaces.each do |name, iface|
        names << "Network Interface #{name}" if iface.tags.includes?(tag)
      end
      checks.network_connections.each do |name, conn|
        names << "Network Connection #{name}" if conn.tags.includes?(tag)
      end
      checks.network_bandwidths.each do |name, bw|
        names << "Bandwidth #{name}" if bw.tags.includes?(tag)
      end
      checks.processes.each do |name, proc_check|
        names << "Process #{name}" if proc_check.tags.includes?(tag)
      end
      checks.files.each do |name, file_check|
        names << "File #{name}" if file_check.tags.includes?(tag)
      end

      names
    end
  end
end

begin
  Jane::CLI.run
rescue ex
  puts "Error running Jane: #{ex.message}"
end
