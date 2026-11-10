require "socket"
require "http/client"
require "openssl"
require "../version"
require "./tls"
require "json"
require "../info"
require "../monitor"
require "../config"

## all metrics, checks and anything related to Network
## submodules: Interface, Connection, Bandwidth

module Jane
  module Network
    extend self

    # ----------------------------------------------------------------
    # Network::Interface — checks if a network interface is up or down
    # ----------------------------------------------------------------
    module Interface
      extend self

      # Reads the operstate of a network interface from sysfs.
      # Returns "up", "down", "unknown", etc.
      private def read_operstate(iface_name : String) : String
        path = "/sys/class/net/#{iface_name}/operstate"
        return "missing" unless File.exists?(path)
        File.read(path).strip.downcase
      end

      # Reads basic interface statistics from /sys/class/net/<iface>/statistics
      private def read_iface_stats(iface_name : String) : Hash(Symbol, Int64)?
        base = "/sys/class/net/#{iface_name}/statistics"
        return nil unless Dir.exists?(base)

        result = Hash(Symbol, Int64).new
        {% for counter in [:rx_bytes, :tx_bytes, :rx_packets, :tx_packets, :rx_errors, :tx_errors, :rx_dropped, :tx_dropped] %}
          file = File.join(base, {{ counter.stringify }})
          result[{{ counter }}] = File.read(file).strip.to_i64 if File.exists?(file)
        {% end %}
        result
      rescue
        nil
      end

      private def iface_exists?(iface_name : String) : Bool
        File.exists?("/sys/class/net/#{iface_name}")
      end

      # ---------- CHECKS

      def check_iface(name : String, iface_check : InterfaceCheck) : Array(Monitor::Check)
        results = [] of Monitor::Check

        iface_name = iface_check.interface

        unless iface_exists?(iface_name)
          results << Monitor::Check.new(
            "Network Interface #{name} (#{iface_name})",
            :alert,
            "missing",
            "present",
            "Interface not found on system",
            description: iface_check.name
          )
          return results
        end

        state = read_operstate(iface_name)
        status = (state == "up") ? :ok : :alert
        msg = status == :alert ? "Interface is #{state}" : "Interface is up"

        results << Monitor::Check.new(
          "Network Interface #{name} (#{iface_name})",
          status,
          state,
          "up",
          msg,
          description: iface_check.name
        )

        return results
      end # check_iface

    end # Interface

    # ----------------------------------------------------------------
    # Network::Connection — checks if a host/port is reachable
    # Covers both remote hosts and local service ports (e.g. postfix)
    # ----------------------------------------------------------------
    module Connection
      extend self

      record ProbeResult, ok : Bool, current : String, message : String

      MAX_BODY = 1024 * 1024

      # Opens a TCP connection. With `expect`, also reads the first line the
      # server sends and requires it to match (e.g. "^SSH-"); without it,
      # completing the handshake is enough (HTTP, databases, ...).
      # Returns {ok, message}.
      def port_check(address : String, port : Int32, timeout : Int32, expect : Regex? = nil) : Tuple(Bool, String)
        r = probe(PortProbe.new(address, port, expect), timeout)
        {r.ok, r.message}
      end

      # Runs a port test: TCP connect, optional TLS (with certificate expiry),
      # then an HTTP request or an `expect` banner check. Every configured
      # condition must hold.
      def probe(p : PortProbe, default_timeout : Int32) : ProbeResult
        timeout = Math.max(p.timeout || default_timeout, 1).seconds
        target = "#{p.address}:#{p.port}"
        tcp = TCPSocket.new(p.address, p.port, dns_timeout: timeout, connect_timeout: timeout)
        tcp.read_timeout = timeout
        tcp.write_timeout = timeout
        io = tcp.as(IO)
        cert_note = nil

        if p.ssl
          tls = tls_connect(tcp, p)
          io = tls
          if op = p.cert_op
            cert = tls.peer_certificate
            return ProbeResult.new(false, "no certificate", "#{target} sent no certificate") unless cert
            days = TLSInfo.days_left(cert)
            expires = (Time.utc + days.days).to_s("%Y-%m-%d")
            cert_note = "cert #{days.floor.to_i}d"
            unless Jane.compare(days, op, p.cert_days)
              return ProbeResult.new(false, cert_note,
                "Certificate of #{target} (#{TLSInfo.subject(cert)}) expires in #{days.floor.to_i} days (#{expires}), " \
                "required: valid #{Jane.op_symbol(op)} #{Jane.trim_float(p.cert_days)} days")
            end
          end
        end

        if p.http
          ok, current, message = http_request(io, p)
          current = "#{current}, #{cert_note}" if cert_note
          return ProbeResult.new(ok, current, ok ? "#{p.protocol_name.upcase} #{target}#{p.request}: #{message}" : message)
        end

        if pattern = p.expect
          line = (io.gets || "").strip
          unless pattern.matches?(line)
            return ProbeResult.new(false, "unexpected", "#{target} answered #{line[0, 80].inspect}, expected #{pattern.source.inspect}")
          end
        end
        ProbeResult.new(true, cert_note ? "open, #{cert_note}" : "open", "Port #{p.port} is reachable")
      rescue ex : OpenSSL::SSL::Error
        ProbeResult.new(false, "tls error", "TLS handshake with #{p.address}:#{p.port} failed — #{ex.message}")
      rescue ex : IO::TimeoutError
        ProbeResult.new(false, "timeout", "#{p.address}:#{p.port} timed out — #{ex.message}")
      rescue ex
        ProbeResult.new(false, "closed", "Cannot connect to #{p.address}:#{p.port} — #{ex.message}")
      ensure
        io.try &.close rescue nil
        tcp.try &.close rescue nil
      end

      private def tls_connect(tcp : TCPSocket, p : PortProbe) : OpenSSL::SSL::Socket::Client
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = p.verify ? OpenSSL::SSL::VerifyMode::PEER : OpenSSL::SSL::VerifyMode::NONE
        name = p.host_header || p.address
        # SNI and hostname verification need a name, not an IP address.
        hostname = Socket::IPAddress.valid?(name) ? nil : name
        OpenSSL::SSL::Socket::Client.new(tcp, ctx, sync_close: false, hostname: hostname)
      end

      # Returns {ok, current, message}.
      private def http_request(io : IO, p : PortProbe) : Tuple(Bool, String, String)
        headers = HTTP::Headers{
          "Host"       => p.host_header || (p.port.in?(80, 443) ? p.address : "#{p.address}:#{p.port}"),
          "User-Agent" => "Jane/#{Jane::VERSION}",
          "Accept"     => "*/*",
          "Connection" => "close",
        }
        HTTP::Request.new("GET", p.request, headers).to_io(io)
        io.flush

        result = HTTP::Client::Response.from_io(io, ignore_body: false) do |resp|
          code = resp.status_code
          current = "#{code} #{resp.status_message}".strip
          status_ok = if op = p.status_op
                        Jane.compare(code.to_f64, op, p.status.to_f64)
                      else
                        code < 400
                      end
          unless status_ok
            required = p.status_op ? "#{Jane.op_symbol(p.status_op.not_nil!)} #{p.status}" : "< 400"
            return {false, current, "#{p.protocol_name.upcase} #{p.address}:#{p.port}#{p.request} returned #{current}, required status #{required}"}
          end

          if pattern = p.content
            body = read_capped(resp.body_io)
            matched = pattern.matches?(body)
            want_match = !p.content_op.try(&.ne?)
            if matched != want_match
              return {false, current, "#{p.protocol_name.upcase} #{p.address}:#{p.port}#{p.request} content #{want_match ? "does not match" : "matches"} #{pattern.source.inspect}"}
            end
          end
          {true, current, current}
        end
        result || {false, "no response", "#{p.address}:#{p.port} closed the connection without an HTTP response"}
      end

      private def read_capped(io : IO) : String
        buf = IO::Memory.new
        IO.copy(io, buf, MAX_BODY)
        String.new(buf.to_slice)
      rescue IO::Error
        String.new(buf.not_nil!.to_slice)
      end

      def check_connection(name : String, conn_check : ConnectionCheck, cycle : Int32) : Array(Monitor::Check)
        p = conn_check.probe || PortProbe.new(conn_check.address, conn_check.port, conn_check.expect)
        r = probe(p, cycle)
        [Monitor::Check.new(
          "Network Connection #{name}",
          r.ok ? :ok : :alert,
          r.current,
          p.http ? "#{p.protocol_name} ok" : "open",
          r.message,
          description: conn_check.name
        )]
      end # check_connection

    end # Connection

    # ----------------------------------------------------------------
    # Network::Bandwidth — checks if bandwidth usage exceeds threshold
    # ----------------------------------------------------------------
    module Bandwidth
      extend self

      def check_bandwidth(name : String, bw_check : BandwidthCheck, cycle : Int32) : Array(Monitor::Check)
        results = [] of Monitor::Check
        address = bw_check.address
        port = bw_check.port
        duration = cycle - 1
        duration = 1 if duration < 1

        begin
          unless Process.find_executable("iperf3")
            results << Monitor::Check.new(
              "Bandwidth #{name}",
              :alert,
              "error",
              "",
              "iperf3 is not installed on this system",
              description: bw_check.name
            )
            return results
          end

          output = IO::Memory.new
          error = IO::Memory.new
          connect_timeout_ms = (duration * 1000).to_s
          status = Process.run("iperf3",
            ["-c", address, "-p", port.to_s, "-t", duration.to_s, "--connect-timeout", connect_timeout_ms, "-J"],
            output: output, error: error)

          unless status.success?
            err_msg = error.to_s.strip
            # Parse JSON error if available
            if output.to_s.strip.starts_with?("{")
              begin
                err_json = JSON.parse(output.to_s)
                if err = err_json["error"]?
                  err_msg = err.as_s
                end
              rescue
              end
            end
            results << Monitor::Check.new(
              "Bandwidth #{name}",
              :alert,
              "error",
              "",
              "iperf3 to #{address}:#{port} failed: #{err_msg}",
              description: bw_check.name
            )
            return results
          end

          json = JSON.parse(output.to_s)
          bits_per_second = json["end"]["sum_sent"]["bits_per_second"].as_f
          mbps = bits_per_second / 1_000_000.0

          current = "%.2f Mbps" % mbps

          if limit = bw_check.limit
            status_sym = mbps < limit ? :alert : :ok
            msg = status_sym == :alert ? "Bandwidth below limit" : "Bandwidth OK"
            results << Monitor::Check.new(
              "Bandwidth #{name}",
              status_sym,
              current,
              "%.2f Mbps" % limit,
              msg,
              description: bw_check.name
            )
          else
            results << Monitor::Check.new(
              "Bandwidth #{name}",
              :ok,
              current,
              "",
              "Bandwidth measured (no limit set)",
              description: bw_check.name
            )
          end
        rescue ex
          results << Monitor::Check.new(
            "Bandwidth #{name}",
            :alert,
            "error",
            "",
            "Bandwidth check failed: #{ex.message}",
            description: bw_check.name
          )
        end

        results
      end # check_bandwidth
    end # Bandwidth

  end # Network
end # Jane
