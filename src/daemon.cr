require "json"
require "msgpack"
require "socket"
require "toml"
require "./logger"
require "./monitor"
require "./info"
require "./state"

module Jane
  module Daemon
    extend self

    def run(config : Config, config_path : String = "config.toml")
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

      cycle = config.defaults.cycle

      unless cycle >= 2
        logger.error("Jane cycle time cannot be less than 2 seconds")
        exit 1
      end

      loop do
        begin

          all_checks = Monitor.perform_checks(config)
          unmonitored_tags = State.unmonitored_tags(config_path)
          puts unmonitored_tags
          filtered_checks = all_checks.reject { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }

          config_toml = TOML.parse_file(config_path)
          config_json = JSON.parse(toml_to_json(config_toml))

          results = {
            "checks" => filtered_checks,
            "metrics" => Info.get_metrics,
            "unmonitored" => unmonitored_tags,
            "config" => config_json,
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
    private def serialize_results(results : Hash(String, Array(Jane::Monitor::Check) | Jane::Info::Metrics | Array(String) | JSON::Any))
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

    private def toml_to_json(hash : Hash(String, TOML::Any)) : String
      JSON.build do |json|
        json.object do
          hash.each do |key, value|
            json.field(key) { toml_value_to_json(value, json) }
          end
        end
      end
    end

    private def toml_value_to_json(value : TOML::Any, json : JSON::Builder)
      raw = value.raw
      case raw
      when Hash
        json.object do
          raw.as(Hash(String, TOML::Any)).each do |k, v|
            json.field(k) { toml_value_to_json(v, json) }
          end
        end
      when Array
        json.array do
          raw.as(Array(TOML::Any)).each do |v|
            toml_value_to_json(v, json)
          end
        end
      when String then json.string(raw.as(String))
      when Int64  then json.number(raw.as(Int64))
      when Float64 then json.number(raw.as(Float64))
      when Bool   then json.bool(raw.as(Bool))
      when Time   then json.string(raw.as(Time).to_s)
      else             json.null
      end
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
