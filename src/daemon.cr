require "msgpack"
require "socket"
require "./logger"
require "./system_monitor"

module Jane
  module Daemon
    extend self

    def run(config : Config)
      logger = Logger.new(config.log)
      logger.info("Jane Agent starting...")
      
      unless server = config.hq
        logger.error("No server configuration found")
        exit 1
      end
      
      loop do
        begin
          results = SystemMonitor.perform_checks(config)
          data = serialize_results(results)
          send_to_server(server, data, logger)
          
          logger.debug("Sent #{results.size} checks to server")
          sleep 10.seconds
        rescue ex
          logger.error("Error in daemon loop: #{ex.message}")
          sleep 5.seconds
        end
      end
    end

    private def serialize_results(results : Array(SystemMonitor::CheckResult)) : Bytes
      data = results.map do |r|
        {
          "name" => r.name,
          "status" => r.status.to_s,
          "current" => r.current,
          "limit" => r.limit,
          "message" => r.message,
          "timestamp" => Time.utc.to_unix
        }
      end
      
      data.to_msgpack
    end

    private def send_to_server(server : ServerConfig, data : Bytes, logger : Logger)
      socket = TCPSocket.new(server.host, server.port)
      
      # Send length prefix
      size_bytes = IO::ByteFormat::BigEndian.encode(data.size.to_u32, Bytes.new(4))
      socket.write(size_bytes.not_nil!)
      socket.write(data)
      socket.flush
      socket.close
    rescue ex
      logger.error("Failed to send data to server: #{ex.message}")
    end
  end
end