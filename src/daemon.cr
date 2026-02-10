require "msgpack"
require "socket"
require "./logger"
require "./system_monitor"
require "./system_info"

module Jane
  module Daemon
    extend self

    def run(config : Config)
      logger = Logger.new(config.log)
      logger.info("Jane Agent starting...")

      unless hq = config.hq
        logger.error("No HQ configuration found in config file, exiting..")
        exit 1
      end

      unless hq.host.not_nil!.presence && hq.port.not_nil!
        logger.error("Need to provide HQ hostname/IP and port when running Jane in daemon mode (see Jane config file), exiting..")
        exit 1
      end

      unless cycle = hq.cycle.not_nil!.to_i32
        cycle = 10
      end

      unless cycle >= 2
        logger.error("HQ cycle time cannot be less than 2 seconds")
        exit 1
      end

      loop do
        begin

          results = {
#            "status" => SystemMonitor.perform_checks(config),
            "checks" => SystemMonitor.perform_checks(config),
            "metrics" => SystemInfo.get_metrics
            }

          data = serialize_results(results)
          puts data
          #puts data
  #        send_to_server(hq.host.not_nil!, hq.port.not_nil!, data, cycle, logger)
          logger.info("Sent #{results.size} checks to server")
          sleep cycle.seconds
        rescue ex
          logger.error("Error in daemon loop: #{ex.message}")
          sleep cycle.seconds
        end
      end
    end

#    private_def to_msgpack(results)
    private def serialize_results(results : Hash(String, Array(Jane::SystemMonitor::Check) | Jane::SystemInfo::Metrics))
      #results : Array(SystemMonitor::Check)) : Bytes
      #
      data = results.to_json

      # data = results.map do |r|
      #   {
      #     "name" => r.name,
      #     "status" => r.status.to_s,
      #     "current" => r.current,
      #     "limit" => r.limit,
      #     "message" => r.message,
      #     "timestamp" => Time.utc.to_unix
      #   }
      # end
      puts data
      data.to_msgpack
    end

    private def send_to_server(host : String, port : Int32, data : Bytes, cycle : Int32, logger : Logger)
      logger.debug("sending to #{host}, #{port}")
      socket = TCPSocket.new(host.not_nil!, port.not_nil!, connect_timeout: cycle.seconds)

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
