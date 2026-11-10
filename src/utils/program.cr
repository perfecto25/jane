require "../monitor"
require "../config"
require "../rules/shell"

## program.cr — `check program`: run a command and test its exit status / output

module Jane
  module ProgramChecker
    extend self

    def check_program(name : String, prog : ProgramCheck, cycle : Int32) : Array(Monitor::Check)
      timeout = prog.timeout || cycle
      result = Shell.run(prog.command, timeout.seconds)
      output = result.output.strip
      first_line = output.lines.first? || ""

      if result.timed_out
        return [Monitor::Check.new(
          "Program #{name}", :alert, "timed out", "#{timeout}s",
          "'#{prog.command}' did not finish within #{timeout} seconds",
          policy: prog.policy
        )]
      end

      code = result.exit_code
      if prog.rules.empty?
        return [Monitor::Check.new(
          "Program #{name}", :ok, result.describe, "",
          first_line.empty? ? "'#{prog.command}' ran (no rules)" : first_line
        )]
      end

      prog.rules.map do |rule|
        check_name = prog.rules.size == 1 ? "Program #{name}" : "Program #{name} #{rule.label}"
        case rule.test
        when "status"
          limit = rule.number.not_nil!
          fired = code.nil? || Jane.compare(code.to_f64, rule.op, limit)
          Monitor::Check.new(
            check_name,
            fired ? :alert : :ok,
            result.describe,
            rule.label,
            fired ? "'#{prog.command}' #{result.describe}#{first_line.empty? ? "" : ": #{first_line}"}" : "Exit status OK",
            policy: rule.policy
          )
        else # content
          matched = rule.pattern.not_nil!.matches?(output)
          fired = rule.op.ne? ? !matched : matched
          Monitor::Check.new(
            check_name,
            fired ? :alert : :ok,
            truncate(first_line.empty? ? "(no output)" : first_line),
            rule.label,
            fired ? "Output #{rule.op.ne? ? "does not match" : "matches"} #{rule.pattern.not_nil!.source.inspect}" : "Output OK",
            policy: rule.policy
          )
        end
      end
    end

    private def truncate(s : String, max = 80) : String
      s.size > max ? s[0, max] + "…" : s
    end
  end
end
