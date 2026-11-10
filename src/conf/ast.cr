## ast.cr — syntax tree produced by Conf::Parser from a Monit-style control file

module Jane
  module Conf
    # Source position, carried by every node so errors and warnings can point
    # at the exact line of the control file (including included files).
    record Pos, file : String, line : Int32, col : Int32 do
      def to_s(io : IO) : Nil
        io << file << ':' << line << ':' << col
      end
    end

    class ParseError < Exception
      getter pos : Pos

      def initialize(message : String, @pos : Pos, source_line : String? = nil)
        text = "#{@pos}: #{message}"
        if source_line
          text += "\n    #{source_line}\n    #{" " * (@pos.col - 1)}^"
        end
        super(text)
      end
    end

    enum Op
      GT
      GE
      LT
      LE
      EQ
      NE
      Changed
    end

    # A literal on the right-hand side of a comparison.
    #   80%       → num 80.0, unit "%"
    #   5 GB      → num 5.0,  unit "gb"
    #   "error"   → str "error"
    struct Value
      getter num : Float64?
      getter str : String?
      getter unit : String?

      def initialize(@num : Float64? = nil, @str : String? = nil, @unit : String? = nil)
      end

      def with_unit(unit : String?) : Value
        Value.new(@num, @str, unit)
      end

      def to_s(io : IO) : Nil
        if s = @str
          s.inspect(io)
        else
          n = @num.not_nil!
          io << (n == n.to_i64 ? n.to_i64.to_s : n.to_s)
          io << (@unit == "%" ? "%" : (@unit ? " #{@unit}" : ""))
        end
      end
    end

    # What to do when a rule fires.
    struct Action
      enum Kind
        Alert
        Warn
        Exec
        Restart
        Start
        Stop
        Unmonitor
      end

      getter kind : Kind
      getter command : String?
      getter repeat : Int32? # exec ... repeat every N cycles

      def initialize(@kind : Kind, @command : String? = nil, @repeat : Int32? = nil)
      end
    end

    # One `if <test> [<op> <values>] [for ...] then <action> [else if succeeded then <action>]`.
    class Rule
      property test : String                # normalized test words: "space usage", "content", "not exist", "failed port"
      property arg : String? = nil          # parenthesized argument: loadavg (5min) → "5min"
      property test_args = [] of String     # trailing words of non-comparison tests: failed port 5432 → ["5432"]
      property op : Op? = nil
      property values = [] of Value
      property times : Int32 = 1            # for <times> times within <cycles> cycles / for <n> cycles
      property cycles : Int32 = 1
      property action : Action
      property recovery : Action? = nil
      property pos : Pos

      def initialize(@test, @action, @pos)
      end

      def comparison? : Bool
        !@op.nil?
      end
    end

    # A `check <type> <name> ...` block.
    class Service
      property type : String
      property name : String
      property attrs = {} of String => String   # path, matching, pidfile, interface, address, port, timeout
      property rules = [] of Rule
      property tags = [] of String
      property every : String? = nil            # "15" (cycles) or a cron spec string
      property depends = [] of String
      property start_program : String? = nil
      property stop_program : String? = nil
      property pos : Pos

      def initialize(@type, @name, @pos)
      end
    end

    # A `set ...` statement. `args` keeps the remaining words as key/value
    # pairs where that makes sense (e.g. port → 25900).
    class Setting
      property key : String                     # cycle, log, hq, mailserver, alert
      property value : String
      property args = {} of String => String
      property pos : Pos

      def initialize(@key, @value, @pos)
      end
    end

    class Document
      property settings = [] of Setting
      property services = [] of Service
    end
  end
end
