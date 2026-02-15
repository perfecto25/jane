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

      def check_connection(name : String, conn_check : ConnectionCheck, cycle : Int32) : Array(Monitor::Check)
        results = [] of Monitor::Check

        address = conn_check.address
        port = conn_check.port

        begin
          # dns_timeout and connect_timeout are in seconds
          sock = TCPSocket.new(
            address,
            port,
            dns_timeout: cycle.seconds,
            connect_timeout: cycle.seconds
          )
          sock.read_timeout = cycle.seconds    # raises IO::TimeoutError on read timeout
          response = sock.gets
          status = :ok
          state = "open"
          msg = "Port #{port} is reachable"
        rescue ex
          status = :alert
          state = "closed"
          msg = "Cannot connect to #{address}:#{port} — #{ex.message}"
        ensure
          sock.try &.close
        end

        # begin
        #   sock = TCPSocket.new(address, port, connect_timeout: cycle, dns_timeout: cycle, tcp_keepalive_count: 3)
        #   sock.close
        #   status = :ok
        #   state = "open"
        #   msg = "Port #{port} is reachable"
        # rescue  ex
        #   status = :alert
        #   state = "closed"
        #   msg = "Cannot connect to #{address}:#{port} — #{ex.message}"
        # end

        results << Monitor::Check.new(
          "Network Connection #{name}",
          status,
          state,
          "open",
          msg,
          description: conn_check.name
        )

        return results
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
