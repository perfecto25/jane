require "./policy"
require "./shell"

## engine.cr — turns raw check results into alerts and actions over time
##
## For every result name the engine keeps a sliding window of the last
## `policy.cycles` evaluations. A result is failing when at least
## `policy.times` of them failed:
##
##   for 3 cycles                → 3 failures in the last 3 evaluations (3 in a row)
##   2 times within 30 cycles    → 2 failures in the last 30 evaluations
##
## A raw alert that isn't confirmed yet is reported as ok (with the count in
## the message). Once failing, the result stays in alert until the window
## holds fewer than `times` failures.
##
## Transitions run the policy's commands:
##   ok → failing     commands
##   still failing    commands again every `repeat` cycles, if set
##   failing → ok     recovery_commands

module Jane
  class Engine
    # Receives (check name, commands, reason). The daemon runs them in the
    # background through Executor; specs record them.
    alias Runner = Proc(String, Array(String), String, Nil)

    private class Entry
      property history = Deque(Bool).new
      property failing = false
      property failing_for = 0
      property last_raw : Monitor::Check? = nil
      property last_out : Monitor::Check? = nil
    end

    def initialize(@runner : Runner)
      @entries = {} of String => Entry
    end

    def process(results : Array(Monitor::Check)) : Array(Monitor::Check)
      results.map { |check| evaluate(check) }
    end

    private def evaluate(raw : Monitor::Check) : Monitor::Check
      entry = @entries[raw.name] ||= Entry.new

      # Same object as last time: the scheduler skipped this check this cycle.
      if (last_raw = entry.last_raw) && last_raw.same?(raw) && (last_out = entry.last_out)
        return last_out
      end

      policy = raw.policy
      window = Math.max(policy.cycles, 1)
      entry.history << raw.alert?
      while entry.history.size > window
        entry.history.shift
      end
      failures = entry.history.count(true)
      failing = failures >= policy.times

      if failing && !entry.failing
        entry.failing = true
        entry.failing_for = 0
        run(raw.name, policy.commands, policy.action)
      elsif failing
        entry.failing_for += 1
        if (every = policy.repeat) && every > 0 && entry.failing_for % every == 0
          run(raw.name, policy.commands, "#{policy.action} (repeat)")
        end
      elsif entry.failing
        entry.failing = false
        run(raw.name, policy.recovery_commands, "recovered")
      end

      out = if raw.alert? == failing
              raw
            elsif raw.alert?
              raw.with_status(:ok, "#{raw.message} (#{failures} of #{policy.times} failures, #{policy.window_description}; not alerting yet)")
            else
              raw.with_status(:alert, "#{raw.message} (still alerting: #{failures} failures in the last #{window} cycles)")
            end

      entry.last_raw = raw
      entry.last_out = out
      out
    end

    private def run(name : String, commands : Array(String), reason : String)
      @runner.call(name, commands, reason) unless commands.empty?
    end
  end

  # Runs action commands in the background, one after another (restart runs
  # stop then start), and logs the outcome.
  class Executor
    def initialize(@logger : Logger, @timeout : Time::Span = 60.seconds)
    end

    def runner : Engine::Runner
      ->(name : String, commands : Array(String), reason : String) { run(name, commands, reason) }
    end

    def run(name : String, commands : Array(String), reason : String) : Nil
      spawn do
        commands.each do |cmd|
          @logger.info("#{name}: #{reason}: running '#{cmd}'")
          result = Shell.run(cmd, @timeout)
          output = result.output.strip
          output = output[0, 500] + "…" if output.size > 500
          if result.success?
            @logger.info("#{name}: '#{cmd}' finished (#{result.describe})#{output.empty? ? "" : ": #{output}"}")
          else
            @logger.error("#{name}: '#{cmd}' failed (#{result.describe})#{output.empty? ? "" : ": #{output}"}")
          end
        end
      end
    end
  end
end
