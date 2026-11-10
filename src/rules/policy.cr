## policy.cr — how a check result turns into an alert and actions
##
## Every Monitor::Check carries a Policy taken from the rule that produced it.
## The default policy (a rule without `for N cycles` or an action) fires on
## the first failed cycle and runs no commands.

module Jane
  struct Policy
    getter times : Int32                     # failures needed ...
    getter cycles : Int32                    # ... within this many evaluations
    getter action : String                   # alert, exec, restart, start, stop (for logs)
    getter commands : Array(String)          # run when the result starts failing
    getter repeat : Int32?                   # re-run commands every N cycles while failing
    getter recovery_commands : Array(String) # run when the result recovers

    def initialize(@times = 1, @cycles = 1, @action = "alert", @commands = [] of String,
                   @repeat = nil, @recovery_commands = [] of String)
    end

    def default? : Bool
      @times == 1 && @cycles == 1 && @commands.empty? && @recovery_commands.empty?
    end

    def window_description : String
      @times == @cycles ? "for #{@cycles} cycles" : "#{@times} times within #{@cycles} cycles"
    end
  end
end
