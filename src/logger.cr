require "log"

module Jane
  class Logger
    @log : Log

    def initialize(config : LogConfig)
      @log = Log.for("jane")
      
      level = parse_level(config.level)
      
      formatter = Log::Formatter.new do |entry, io|
        io << "[" << entry.timestamp.to_s("%Y-%m-%d %H:%M:%S") << "] "
        io << entry.severity.to_s.rjust(5) << " -- "
        io << entry.message
      end
      
      backend = case config.destination
      when "syslog"
        Log::IOBackend.new(STDOUT, formatter: formatter)
      when "file"
        if file = config.file
          io = File.open(file, "a")
          Log::IOBackend.new(io, formatter: formatter)
        else
          Log::IOBackend.new(STDOUT, formatter: formatter)
        end
      else
        Log::IOBackend.new(STDOUT, formatter: formatter)
      end
      
      Log.setup(level, backend)
    end

    private def parse_level(level_str : String) : Log::Severity
      case level_str.downcase
      when "debug"   then Log::Severity::Debug
      when "info"    then Log::Severity::Info
      when "warn"    then Log::Severity::Warn
      when "error"   then Log::Severity::Error
      when "fatal"   then Log::Severity::Fatal
      else                Log::Severity::Info
      end
    end

    def debug(message : String)
      @log.debug { message }
    end

    def info(message : String)
      @log.info { message }
    end

    def warn(message : String)
      @log.warn { message }
    end

    def error(message : String)
      @log.error { message }
    end

    def fatal(message : String)
      @log.fatal { message }
    end
  end
end