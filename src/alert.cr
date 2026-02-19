require "socket"
require "./monitor"
require "./logger"
require "./config"

module Jane
  class Alerter
    # Tracks the previous alert state of each check by name.
    # Only sends an email when a check transitions from ok -> alert.
    @previous_states : Hash(String, String)
    @logger : Logger

    def initialize(@email_config : AlertEmailConfig, @logger : Logger)
      @previous_states = Hash(String, String).new
    end

    # Process a batch of check results. Sends alert emails for any check
    # that has just entered the alert state (was not alert on the previous cycle).
    def process(checks : Array(Monitor::Check))
      newly_alerted = [] of Monitor::Check

      checks.each do |check|
        prev = @previous_states[check.name]?
        if check.alert? && prev != "alert"
          newly_alerted << check
        end
        @previous_states[check.name] = check.status
      end

      if newly_alerted.any?
        send_alert_email(newly_alerted)
      end
    end

    private def send_alert_email(checks : Array(Monitor::Check))
      to = @email_config.send_to
      cc = @email_config.send_cc
      server = @email_config.smtp_server
      port = @email_config.smtp_port

      hostname = System.hostname rescue "jane-agent"
      subject = "Jane Alert: #{checks.size} check(s) entered alert state on #{hostname}"

      body = String.build do |io|
        io << "The following checks have entered alert state:\n\n"
        checks.each do |check|
          io << "  Check:     #{check.name}\n"
          io << "  Status:    #{check.status}\n"
          io << "  Current:   #{check.current}\n"
          io << "  Threshold: #{check.threshold}\n"
          io << "  Message:   #{check.message}\n"
          io << "\n"
        end
        io << "---\nSent by Jane Agent on #{hostname} at #{Time.local}\n"
      end

      recipients = [to]
      recipients << cc if cc && !cc.empty?

      message = String.build do |io|
        io << "From: jane@#{hostname}\r\n"
        io << "To: #{to}\r\n"
        io << "Cc: #{cc}\r\n" if cc && !cc.empty?
        io << "Subject: #{subject}\r\n"
        io << "Date: #{Time.utc.to_rfc2822}\r\n"
        io << "Content-Type: text/plain; charset=UTF-8\r\n"
        io << "\r\n"
        io << body
      end

      begin
        send_smtp(server, port, "jane@#{hostname}", recipients, message)
        @logger.info("Alert email sent for #{checks.size} check(s): #{checks.map(&.name).join(", ")}")
      rescue ex
        @logger.error("Failed to send alert email: #{ex.message}")
      end
    end

    private def send_smtp(server : String, port : Int32, from : String, recipients : Array(String), message : String)
      socket = TCPSocket.new(server, port, connect_timeout: 10.seconds)
      begin
        expect_reply(socket, 220)

        hostname = System.hostname rescue "localhost"
        send_command(socket, "EHLO #{hostname}", 250)
        send_command(socket, "MAIL FROM:<#{from}>", 250)
        recipients.each do |rcpt|
          send_command(socket, "RCPT TO:<#{rcpt}>", 250)
        end
        send_command(socket, "DATA", 354)
        socket.print(message)
        socket.print("\r\n.\r\n")
        expect_reply(socket, 250)
        send_command(socket, "QUIT", 221)
      ensure
        socket.close
      end
    end

    private def send_command(socket : TCPSocket, command : String, expected_code : Int32)
      socket.print("#{command}\r\n")
      socket.flush
      expect_reply(socket, expected_code)
    end

    private def expect_reply(socket : TCPSocket, expected_code : Int32)
      response = ""
      loop do
        line = socket.gets || ""
        response += line + "\n"
        # SMTP multi-line responses have a dash after the code; last line has a space
        break if line.size >= 4 && line[3]? == ' '
        break if line.empty?
      end
      code = response[0, 3].to_i rescue 0
      unless code == expected_code
        raise "SMTP error: expected #{expected_code}, got: #{response.strip}"
      end
    end
  end
end
