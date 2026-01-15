require "option_parser"
require "./config"
require "./system_info"
require "./system_monitor"
require "./daemon"
require "./logger"

module Jane
  VERSION = "0.1.0"

  class CLI
    def self.run
      mode = :help
      config_path = "config.toml"

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
        SystemInfo.display
      when :status
        config = Config.from_file(config_path)
        SystemMonitor.display_status(config)
      when :daemon
        config = Config.from_file(config_path)
        Daemon.run(config)
      when :help
        puts "Usage: jane [options]"
        puts "  -i, --info              Show system information"
        puts "  -s, --status            Show system status vs config"
        puts "  -d, --daemon            Run as daemon"
        puts "  -c, --config FILE       Config file path (default: config.toml)"
        puts "  -h, --help              Show help"
        puts "  -v, --version           Show version"
      end
    end
  end
end

Jane::CLI.run