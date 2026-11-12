require "json"
require "msgpack"
require "socket"
require "./logger"
require "./monitor"
require "./info"
require "./state"
require "./alert"

module Jane
  module Daemon
    extend self

    def run(config : Config, config_path : String = DEFAULT_CONFIG)
      logger = Logger.new(config.log)
      logger.info("Jane Agent starting...")

      cycle = config.defaults.cycle || 5

      unless cycle >= 2
        logger.error("'set cycle' cannot be less than 2 seconds")
        exit 1
      end

      hq = config.hq
      hq_enabled = hq && hq.enabled

      if hq_enabled
        unless hq.not_nil!.host.not_nil!.presence && hq.not_nil!.port.not_nil!
          logger.error("Need to provide HQ hostname/IP and port when running Jane in daemon mode (set hq <host> port <n>), exiting..")
          exit 1
        end
        logger.info("HQ mode: sending metrics to #{hq.not_nil!.host}:#{hq.not_nil!.port}")
        run_hq_loop(config, config_path, hq.not_nil!, cycle, logger)
      else
        logger.info("HQ is disabled — running in standalone alert mode")
        alert_config = config.alert
        email_config = alert_config.try(&.email)
        unless email_config && !email_config.smtp_server.empty? && !email_config.send_to.empty?
          logger.error("No 'set hq', and no email alerts configured (need 'set mailserver' and 'set alert'), exiting..")
          exit 1
        end
        run_alert_loop(config, config_path, email_config, cycle, logger)
      end
    end

    # One evaluation: run the due checks, drop unmonitored ones, then let the
    # engine apply cycle windows and run actions. Unmonitored checks never
    # trigger actions.
    private def evaluate(config : Config, config_path : String, scheduler : Scheduler, engine : Engine) : Array(Monitor::Check)
      scheduler.tick
      all_checks = Monitor.perform_checks(config, scheduler)
      unmonitored_tags = State.unmonitored_tags(config_path)
      monitored = all_checks.reject { |c| c.tags.any? { |t| unmonitored_tags.includes?(t) } }
      Monitor.collapse_levels(engine.process(monitored))
    end

    # HQ receives the raw text of the control file.
    private def config_payload(config_path : String) : JSON::Any
      JSON::Any.new({"format" => JSON::Any.new("control"), "source" => JSON::Any.new(File.read(config_path))})
    end

    private def run_hq_loop(config : Config, config_path : String, hq : HQConfig, cycle : Int32, logger : Logger)
      scheduler = Scheduler.new
      engine = Engine.new(Executor.new(logger).runner)
      loop do
        begin
          filtered_checks = evaluate(config, config_path, scheduler, engine)
          unmonitored_tags = State.unmonitored_tags(config_path)
          config_json = config_payload(config_path)

          results = {
            "checks" => filtered_checks,
            "metrics" => Info.get_metrics,
            "unmonitored" => unmonitored_tags,
            "config" => config_json,
          }

          data = serialize_results(results, logger)
          #logger.info(data.to_s)
          send_to_server(hq.host.not_nil!, hq.port.not_nil!, data, cycle, logger)
          logger.info("Sent #{filtered_checks.size} checks to server")
          sleep cycle.seconds
        rescue ex
          logger.error("Error in daemon loop: #{ex.message}")
          sleep cycle.seconds
        end
      end
    end

    private def run_alert_loop(config : Config, config_path : String, email_config : AlertEmailConfig, cycle : Int32, logger : Logger)
      alerter = Alerter.new(email_config, logger)
      logger.info("Standalone alert mode: emails to #{email_config.send_to} via #{email_config.smtp_server}:#{email_config.smtp_port}")
      scheduler = Scheduler.new
      engine = Engine.new(Executor.new(logger).runner)
      loop do
        begin
          filtered_checks = evaluate(config, config_path, scheduler, engine)
          alerter.process(filtered_checks)

          logger.debug("Cycle complete: #{filtered_checks.size} checks evaluated")
          sleep cycle.seconds
        rescue ex
          logger.error("Error in alert loop: #{ex.message}")
          sleep cycle.seconds
        end
      end
    end

#    private_def to_msgpack(results)
    private def serialize_results(results : Hash(String, Array(Jane::Monitor::Check) | Jane::Info::Metrics | Array(String) | JSON::Any), logger : Logger)
      #results : Array(SystemMonitor::Check)) : Bytes
      #
      data = results.to_json
      logger.debug(data.to_s)

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
#      puts data
      data.to_msgpack
    end

    private def send_to_server(host : String, port : Int32, data : Bytes, cycle : Int32, logger : Logger)
      #logger.warn(data.to_s)
      logger.debug("sending to #{host}, #{port}")
 
      socket = TCPSocket.new(host.not_nil!, port.not_nil!, connect_timeout: cycle.seconds).not_nil!

      write_data = data.not_nil!
      # Send length prefix
      # begin
      #   size_bytes = IO::ByteFormat::BigEndian.encode(data.size.to_u32, Bytes.new(4))
      #   logger.debug(size_bytes.to_s)
      # rescue
      #   logger.error("sizebytes")
      # end

      # begin
      #   socket.write(size_bytes.not_nil!)
      # rescue 
      #   logger.error("socket write")
      # end
      socket.write(write_data)
      socket.flush
      socket.close
    rescue ex
      logger.error("Failed to send data to server: #{ex.message}")
    end
  end
end
