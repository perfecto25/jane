## shell.cr — run a shell command with a timeout, capturing its output
##
## Used by `check program` and by exec/restart/start/stop actions.

module Jane
  module Shell
    extend self

    MAX_OUTPUT = 64 * 1024

    record Result, exit_code : Int32?, output : String, timed_out : Bool do
      def success? : Bool
        !timed_out && exit_code == 0
      end

      def describe : String
        if timed_out
          "timed out"
        elsif code = exit_code
          "exit status #{code}"
        else
          "killed by a signal"
        end
      end
    end

    # Runs `command` through /bin/sh. stdout and stderr are captured together
    # (capped at MAX_OUTPUT). On timeout the process is killed.
    def run(command : String, timeout : Time::Span) : Result
      process = Process.new(command, shell: true,
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)

      buffer = IO::Memory.new
      readers = Channel(Nil).new(2)
      {process.output, process.error}.each do |pipe|
        spawn do
          copy_capped(pipe, buffer)
          readers.send(nil)
        end
      end

      exited = Channel(Process::Status).new(1)
      spawn { exited.send(process.wait) }

      select
      when status = exited.receive
        # A background grandchild can keep the pipes open; don't wait for it forever.
        2.times do
          select
          when readers.receive
          when timeout(1.second)
            break
          end
        end
        code = status.normal_exit? ? status.exit_code : nil
        Result.new(code, buffer.to_s, false)
      when timeout(timeout)
        process.terminate(graceful: false) rescue nil
        Result.new(nil, buffer.to_s, true)
      end
    rescue ex : IO::Error | File::Error
      Result.new(127, "cannot run '#{command}': #{ex.message}", false)
    end

    private def copy_capped(from : IO, to : IO::Memory)
      chunk = Bytes.new(4096)
      while (n = from.read(chunk)) > 0
        room = MAX_OUTPUT - to.size
        to.write(chunk[0, Math.min(n, room)]) if room > 0
      end
    rescue IO::Error
    end
  end
end
