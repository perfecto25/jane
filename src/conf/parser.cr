require "./ast"
require "./lexer"

## parser.cr — recursive-descent parser for Monit-style control files
##
##   config   := (check | set | include | ';')*
##   check    := "check" TYPE NAME (source | option | rule)*
##   rule     := "if" TEST [OP values] [cycles] "then" action ["else if succeeded then" action]
##   values   := value ("," value)* [UNIT]        e.g.  75, 80, 85 %
##   cycles   := ["for"] N "cycles" | ["for"] N "times within" M "cycles"
##   action   := "alert" | "warn" | "exec" STRING ["repeat every" N "cycles"]
##             | "restart" | "start" | "stop" | "unmonitor"
##
## The parser only checks syntax. Whether a test makes sense for a service
## type (e.g. `content` on a process) is decided by Conf::Builder.

module Jane
  module Conf
    class Parser
      SERVICE_TYPES = %w(system filesystem file directory fifo process program host network bandwidth)

      # Words Monit accepts for readability and that carry no meaning.
      NOISE = %w(is than the)

      OP_WORDS = {
        "gt" => Op::GT, "greater" => Op::GT,
        "ge" => Op::GE,
        "lt" => Op::LT, "less" => Op::LT,
        "le" => Op::LE,
        "eq" => Op::EQ, "equal" => Op::EQ,
        "ne" => Op::NE, "notequal" => Op::NE,
      }

      OP_SYMBOLS = {
        ">" => Op::GT, ">=" => Op::GE, "<" => Op::LT, "<=" => Op::LE,
        "=" => Op::EQ, "==" => Op::EQ, "!=" => Op::NE, "<>" => Op::NE,
      }

      UNITS = %w(% b kb mb gb tb pb k m g t bps kbps mbps gbps s sec second seconds min minute minutes h hour hours d day days ms)

      NUMBER_WITH_UNIT = /\A(-?\d+(?:\.\d+)?)([a-zA-Z%]*(?:\/[a-zA-Z]+)?)\z/

      # Rates: <size or operations>/<period>, e.g. MB/s, kb/min, operations/s
      RATE_BASES   = %w(b kb mb gb tb k m g t operation operations ops op)
      RATE_PERIODS = %w(s sec second m min minute h hour d day)

      def self.unit?(unit : String) : Bool
        return true if UNITS.includes?(unit)
        base, slash, period = unit.partition('/')
        !slash.empty? && RATE_BASES.includes?(base) && RATE_PERIODS.includes?(period)
      end

      MAX_INCLUDE_DEPTH = 10

      getter document : Document
      getter warnings : Array(Tuple(Pos, String))

      def self.parse_file(path : String) : Parser
        parser = new
        parser.parse_file(path)
        parser
      end

      def self.parse_string(source : String, file : String = "<string>") : Parser
        parser = new
        parser.parse_source(source, file)
        parser
      end

      def initialize
        @document = Document.new
        @warnings = [] of Tuple(Pos, String)
        @tokens = [] of Token
        @lines = [] of String
        @idx = 0
        @depth = 0
      end

      def parse_file(path : String) : Nil
        parse_source(File.read(path), path)
      end

      def parse_source(source : String, file : String) : Nil
        lexer = Lexer.new(source, file)
        tokens = lexer.tokenize
        # Save state so `include` can parse another file and come back.
        saved = {@tokens, @lines, @idx}
        @tokens, @lines, @idx = tokens, lexer.lines, 0
        begin
          parse_statements
        ensure
          @tokens, @lines, @idx = saved
        end
      end

      # ---------------------------------------------------------------- statements

      private def parse_statements
        until current.kind.eof?
          tok = current
          if tok.kind.semi?
            advance
          elsif tok.word?("check")
            parse_check
          elsif tok.word?("set")
            parse_set
          elsif tok.word?("include")
            parse_include
          else
            error("expected 'check', 'set' or 'include', got #{tok}", tok)
          end
        end
      end

      private def statement_start?(tok : Token) : Bool
        tok.kind.eof? || tok.word?("check") || tok.word?("set") || tok.word?("include")
      end

      private def parse_include
        kw = advance
        pattern = expect_value("a file or glob pattern after 'include'")
        base = File.dirname(kw.pos.file)
        pattern = File.join(base, pattern) unless pattern.starts_with?('/') || kw.pos.file == "<string>"

        if @depth >= MAX_INCLUDE_DEPTH
          error("includes nested more than #{MAX_INCLUDE_DEPTH} levels deep", kw)
        end
        @depth += 1
        begin
          Dir.glob(pattern).sort.each do |path|
            next unless File.file?(path)
            parse_file(path)
          end
        ensure
          @depth -= 1
        end
      end

      # ---------------------------------------------------------------- set

      private def parse_set
        set_tok = advance
        key_tok = current
        error("expected a setting name after 'set'", key_tok) unless key_tok.kind.word?
        key = key_tok.text.downcase
        advance

        case key
        when "cycle", "daemon"
          # `set daemon` is Monit's name; still accepted so monitrc files load.
          warn(key_tok.pos, "'set daemon' is deprecated, use 'set cycle #{current.text}'") if key == "daemon"
          setting = Setting.new("cycle", expect_integer("cycle length in seconds after 'set #{key}'").to_s, set_tok.pos)
          skip_word("with")
          if current.word?("start")
            advance
            expect_word("delay")
            setting.args["start_delay"] = expect_integer("start delay in seconds").to_s
          end
          @document.settings << setting
        when "log"
          setting = Setting.new("log", expect_value("'syslog' or a log file path after 'set log'"), set_tok.pos)
          loop do
            if current.word?("level")
              advance
              setting.args["level"] = expect_value("a log level")
            elsif current.word?("facility")
              advance
              setting.args["facility"] = expect_value("a syslog facility")
            else
              break
            end
          end
          @document.settings << setting
        when "hq"
          setting = Setting.new("hq", expect_value("an HQ host after 'set hq'"), set_tok.pos)
          parse_port_arg(setting)
          @document.settings << setting
        when "mailserver"
          setting = Setting.new("mailserver", expect_value("an SMTP host after 'set mailserver'"), set_tok.pos)
          parse_port_arg(setting)
          @document.settings << setting
        when "alert"
          setting = Setting.new("alert", expect_value("an email address after 'set alert'"), set_tok.pos)
          if current.word?("cc")
            advance
            setting.args["cc"] = expect_value("an email address after 'cc'")
          end
          @document.settings << setting
        else
          # httpd, eventqueue, idfile, statefile, mail-format, ... — common in
          # monitrc files but meaningless for Jane. Skip the whole statement.
          warn(set_tok.pos, "'set #{key}' is not supported by Jane and was ignored")
          until statement_start?(current)
            advance
          end
        end
      end

      private def parse_port_arg(setting : Setting)
        skip_word("with")
        if current.word?("port")
          advance
          setting.args["port"] = expect_integer("a port number").to_s
        end
      end

      # ---------------------------------------------------------------- check

      private def parse_check
        check_tok = advance
        type_tok = current
        unless type_tok.kind.word? && SERVICE_TYPES.includes?(type_tok.text.downcase)
          error("unknown check type #{type_tok}, expected one of: #{SERVICE_TYPES.join(", ")}", type_tok)
        end
        advance

        name_tok = current
        unless name_tok.kind.word? || name_tok.kind.string?
          error("expected a name after 'check #{type_tok.text}', got #{name_tok}", name_tok)
        end
        advance

        service = Service.new(type_tok.text.downcase, name_tok.text, check_tok.pos)

        until statement_start?(current)
          tok = current
          if tok.kind.semi? || tok.word?("with") || tok.word?("using") || tok.word?("and")
            advance
          elsif tok.word?("if")
            service.rules << parse_rule
          elsif tok.word?("path") || tok.word?("pidfile") || tok.word?("interface") ||
                tok.word?("address") || tok.word?("matching")
            attr = tok.text.downcase
            advance
            service.attrs[attr] = expect_value("a value after '#{attr}'")
          elsif tok.word?("port")
            advance
            service.attrs["port"] = expect_integer("a port number").to_s
          elsif tok.word?("timeout")
            advance
            service.attrs["timeout"] = expect_integer("a timeout in seconds").to_s
            skip_unit_seconds
          elsif tok.word?("every")
            advance
            if current.kind.string?
              service.every = advance.text
            else
              service.every = expect_integer("a number of cycles after 'every'").to_s
              expect_word("cycles", "cycle")
            end
          elsif tok.word?("group") || tok.word?("tag")
            advance
            service.tags.concat(parse_word_list("a #{tok.text.downcase} name"))
          elsif tok.word?("depends")
            advance
            skip_word("on")
            service.depends.concat(parse_word_list("a service name after 'depends on'"))
          elsif tok.word?("start") || tok.word?("stop") || tok.word?("restart")
            which = tok.text.downcase
            advance
            expect_word("program")
            expect_op("=")
            cmd = expect_value("a command after '#{which} program ='")
            case which
            when "start"   then service.start_program = cmd
            when "stop"    then service.stop_program = cmd
            else
              warn(tok.pos, "'restart program' is not supported, use start/stop program")
            end
            skip_word("with")
            if current.word?("timeout")
              advance
              expect_integer("a timeout in seconds")
              skip_unit_seconds
            end
          else
            error("unexpected #{tok} in 'check #{service.type} #{service.name}'", tok)
          end
        end

        @document.services << service
      end

      # ---------------------------------------------------------------- if ... then ...

      private def parse_rule : Rule
        if_tok = advance
        words = [] of String
        arg = nil
        op = nil

        if current.word?("changed")
          advance
          op = Op::Changed
        end

        # Test words run until an operator, a cycle spec or 'then'.
        loop do
          tok = current
          if tok.kind.l_paren?
            advance
            arg = expect_value("an argument inside '( )'")
            unless current.kind.r_paren?
              error("expected ')', got #{current}", current)
            end
            advance
          elsif tok.kind.word? && !rule_boundary?(tok)
            advance
            words << tok.text unless NOISE.includes?(tok.text.downcase)
          else
            break
          end
        end

        error("expected a test after 'if'", if_tok) if words.empty?

        # Split the test name from its arguments:
        #   failed port 5432 protocol http → "failed port" ["5432", "protocol", "http"]
        #   failed uid root                → "failed uid"  ["root"]
        split = if words.first.downcase == "failed"
                  Math.min(2, words.size)
                else
                  words.index { |w| w =~ /\A\d/ } || words.size
                end
        test_words = words[0...split].map(&.downcase)
        test_args = words[split..]
        test_words.shift if test_words.first? == "does" # "does not exist" → "not exist"
        error("expected a test after 'if'", if_tok) if test_words.empty?

        if op.nil? && test_words.first? == "failed" && test_words[1]?.in?("port", "host")
          # Port tests carry their own options, including comparisons:
          #   failed port 443 protocol https request "/health" status = 200
          #     content = "ok" and certificate valid > 30 days
          # Keep every token as an argument; the builder interprets them.
          loop do
            tok = current
            break if tok.word?("then") || tok.word?("for") ||
                     (tok.kind.word? && tok.text =~ /\A\d+\z/ && peek_word?(1, "times", "cycles", "cycle"))
            break unless tok.kind.word? || tok.kind.string? || tok.kind.op?
            advance
            test_args << tok.text unless tok.kind.word? && NOISE.includes?(tok.text.downcase)
          end
        elsif op.nil?
          # Quoted arguments of non-comparison tests: if failed uid "root"
          while current.kind.string?
            test_args << advance.text
          end
        end

        rule = Rule.new(test_words.join(" "), Action.new(Action::Kind::Alert), if_tok.pos)
        rule.arg = arg
        rule.test_args = test_args

        if op.nil? && (parsed = parse_op?)
          op = parsed
        end
        rule.op = op
        rule.values = parse_values if op && op != Op::Changed

        parse_cycles(rule)

        then_tok = current
        unless then_tok.word?("then")
          error("expected 'then', got #{then_tok}", then_tok)
        end
        advance
        rule.action = parse_action

        if current.word?("else")
          advance
          expect_word("if")
          expect_word("succeeded", "passed", "recovered")
          expect_word("then")
          rule.recovery = parse_action
        end

        rule
      end

      private def rule_boundary?(tok : Token) : Bool
        w = tok.text.downcase
        OP_WORDS.has_key?(w) || w == "then" || w == "for" ||
          (!!(w =~ /\A\d+\z/) && peek_word?(1, "times", "cycles", "cycle"))
      end

      private def parse_op? : Op?
        tok = current
        if tok.kind.op?
          advance
          return OP_SYMBOLS[tok.text]
        end
        if tok.kind.word? && (op = OP_WORDS[tok.text.downcase]?)
          advance
          skip_word("than", "to")
          return op
        end
        nil
      end

      # 80%  |  75, 80, 85 %  |  5 GB  |  "kernel: BUG"  |  0
      private def parse_values : Array(Value)
        values = [] of Value
        loop do
          values << parse_value
          break unless current.kind.comma?
          advance
        end

        # A trailing unit applies to every value that didn't carry its own.
        # So does a unit written on the last value only: 75, 80, 85% == 75, 80, 85 %
        if current.kind.word? && current.text.includes?('/') && !Parser.unit?(current.text.downcase)
          error("unknown unit '#{current.text}'", current)
        end
        unit = if current.kind.word? && Parser.unit?(current.text.downcase)
                 advance.text.downcase
               elsif values.size > 1 && values[0...-1].all? { |v| v.num && v.unit.nil? }
                 values.last.unit
               end
        if unit
          values = values.map { |v| v.num && v.unit.nil? ? v.with_unit(unit) : v }
        end
        values
      end

      private def parse_value : Value
        tok = current
        if tok.kind.string?
          advance
          return Value.new(str: tok.text)
        end
        unless tok.kind.word?
          error("expected a value, got #{tok}", tok)
        end
        advance
        if m = tok.text.match(NUMBER_WITH_UNIT)
          unit = m[2].empty? ? nil : m[2].downcase
          if unit && !Parser.unit?(unit)
            error("unknown unit '#{m[2]}' in #{tok}", tok)
          end
          Value.new(num: m[1].to_f64, unit: unit)
        else
          Value.new(str: tok.text) # bare word, e.g. `if uid != root`
        end
      end

      private def parse_cycles(rule : Rule)
        for_tok = current
        had_for = skip_word("for")
        unless current.kind.word? && current.text =~ /\A\d+\z/
          error("expected a number of cycles after 'for'", current) if had_for
          return
        end
        n = expect_integer("a number")
        if current.word?("times")
          advance
          expect_word("within")
          m = expect_integer("a number of cycles after 'within'")
          expect_word("cycles", "cycle")
          error("'#{n} times within #{m} cycles' can never be satisfied", for_tok) if n > m
          rule.times, rule.cycles = n, m
        else
          expect_word("cycles", "cycle")
          rule.times, rule.cycles = n, n
        end
      end

      private def parse_action : Action
        tok = current
        error("expected an action after 'then', got #{tok}", tok) unless tok.kind.word?
        advance
        action = case tok.text.downcase
                 when "alert"     then Action.new(Action::Kind::Alert)
                 when "warn"      then Action.new(Action::Kind::Warn)
                 when "restart"   then Action.new(Action::Kind::Restart)
                 when "start"     then Action.new(Action::Kind::Start)
                 when "stop"      then Action.new(Action::Kind::Stop)
                 when "unmonitor" then Action.new(Action::Kind::Unmonitor)
                 when "exec"
                   Action.new(Action::Kind::Exec, expect_value("a command after 'exec'"))
                 else
                   error("unknown action #{tok}, expected alert, warn, exec, restart, start, stop or unmonitor", tok)
                 end

        # exec "..." [as uid X [and gid Y]] [repeat every N cycles] — Monit extras.
        repeat = nil.as(Int32?)
        loop do
          if current.word?("as") || current.word?("and") && peek_word?(1, "gid")
            advance
            expect_word("uid", "gid")
            expect_value("a user or group")
          elsif current.word?("repeat") || current.word?("and") && peek_word?(1, "repeat")
            skip_word("and")
            advance
            expect_word("every")
            repeat = expect_integer("a number of cycles")
            expect_word("cycles", "cycle")
          else
            break
          end
        end
        repeat ? Action.new(action.kind, action.command, repeat) : action
      end

      # ---------------------------------------------------------------- helpers

      private def parse_word_list(what : String) : Array(String)
        list = [expect_value(what)]
        while current.kind.comma?
          advance
          list << expect_value(what)
        end
        list
      end

      private def skip_unit_seconds
        skip_word("s", "sec", "second", "seconds")
      end

      private def current : Token
        @tokens[@idx]
      end

      private def advance : Token
        tok = @tokens[@idx]
        @idx += 1 unless tok.kind.eof?
        tok
      end

      private def peek_word?(offset : Int32, *words : String) : Bool
        tok = @tokens[@idx + offset]?
        return false unless tok
        words.any? { |w| tok.word?(w) }
      end

      private def skip_word(*words : String) : Bool
        if words.any? { |w| current.word?(w) }
          advance
          true
        else
          false
        end
      end

      private def expect_word(*words : String) : Token
        tok = current
        unless words.any? { |w| tok.word?(w) }
          expected = words.map { |w| "'#{w}'" }.join(" or ")
          error("expected #{expected}, got #{tok}", tok)
        end
        advance
      end

      private def expect_op(op : String) : Token
        tok = current
        error("expected '#{op}', got #{tok}", tok) unless tok.kind.op? && tok.text == op
        advance
      end

      private def expect_value(what : String) : String
        tok = current
        if (tok.kind.word? && !statement_start?(tok)) || tok.kind.string?
          advance
          tok.text
        else
          error("expected #{what}, got #{tok}", tok)
        end
      end


      private def expect_integer(what : String) : Int32
        tok = current
        if tok.kind.word? && (n = tok.text.to_i32?)
          advance
          n
        else
          error("expected #{what}, got #{tok}", tok)
        end
      end

      private def warn(pos : Pos, message : String)
        @warnings << {pos, message}
      end

      private def error(message : String, tok : Token) : NoReturn
        raise ParseError.new(message, tok.pos, source_line(tok.pos))
      end

      private def source_line(pos : Pos) : String?
        @lines[pos.line - 1]?
      end
    end
  end
end
