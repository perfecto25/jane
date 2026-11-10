require "./ast"

## lexer.cr — turns a Monit-style control file into tokens
##
## The grammar is newline-insensitive (like Monit): statements are recognised
## by their leading keyword, so newlines are just whitespace. `;` and `,` are
## kept as tokens; `#` outside a string starts a comment to end of line.

module Jane
  module Conf
    struct Token
      enum Kind
        Word      # bare word: check, /var/log, qbtch2-/mnt/hc, 80%, 5min
        String    # "quoted" or 'quoted'
        Op        # > >= < <= = == != <>
        Comma
        Semi
        LParen
        RParen
        EOF
      end

      getter kind : Kind
      getter text : ::String
      getter pos : Pos

      def initialize(@kind : Kind, @text : ::String, @pos : Pos)
      end

      def word?(w : ::String) : Bool
        @kind.word? && @text.downcase == w
      end

      def to_s(io : IO) : Nil
        case @kind
        when .eof?    then io << "end of file"
        when .string? then @text.inspect(io)
        else               io << '\'' << @text << '\''
        end
      end
    end

    class Lexer
      DELIMITERS = {' ', '\t', '\n', '\r', '"', '\'', ',', ';', '(', ')', '>', '<', '=', '!', '#'}

      getter lines : Array(String)

      def initialize(@source : String, @file : String = "<string>")
        @lines = @source.split('\n')
        @chars = @source.chars
        @i = 0
        @line = 1
        @col = 1
      end

      def tokenize : Array(Token)
        tokens = [] of Token
        loop do
          tok = next_token
          tokens << tok
          break if tok.kind.eof?
        end
        tokens
      end

      private def next_token : Token
        skip_space_and_comments
        pos = Pos.new(@file, @line, @col)
        return Token.new(Token::Kind::EOF, "", pos) if eof?

        c = peek
        case c
        when '"', '\''
          Token.new(Token::Kind::String, read_string(c, pos), pos)
        when ','
          advance; Token.new(Token::Kind::Comma, ",", pos)
        when ';'
          advance; Token.new(Token::Kind::Semi, ";", pos)
        when '('
          advance; Token.new(Token::Kind::LParen, "(", pos)
        when ')'
          advance; Token.new(Token::Kind::RParen, ")", pos)
        when '>', '<', '=', '!'
          Token.new(Token::Kind::Op, read_op(pos), pos)
        else
          Token.new(Token::Kind::Word, read_word, pos)
        end
      end

      private def skip_space_and_comments
        until eof?
          c = peek
          if c == '#'
            until eof? || peek == '\n'
              advance
            end
          elsif c.whitespace?
            advance
          else
            break
          end
        end
      end

      private def read_string(quote : Char, pos : Pos) : String
        advance # opening quote
        buf = String::Builder.new
        loop do
          raise ParseError.new("unterminated string", pos, @lines[pos.line - 1]?) if eof?
          c = advance
          break if c == quote
          # Only \" (or \') and \\ are escapes. Other backslashes are kept, so
          # regexes work as written: "myapp\.sh", "\[listener\]", "\d+".
          if c == '\\' && !eof? && (peek == quote || peek == '\\')
            buf << advance
          else
            buf << c
          end
        end
        buf.to_s
      end

      private def read_op(pos : Pos) : String
        first = advance
        second = eof? ? nil : peek
        op = case {first, second}
             when {'>', '='}, {'<', '='}, {'=', '='}, {'!', '='}, {'<', '>'}
               advance
               "#{first}#{second}"
             else
               first.to_s
             end
        raise ParseError.new("unexpected '!'", pos, @lines[pos.line - 1]?) if op == "!"
        op
      end

      private def read_word : String
        start = @i
        until eof? || DELIMITERS.includes?(peek)
          advance
        end
        String.build { |io| @chars[start...@i].each { |ch| io << ch } }
      end

      private def eof? : Bool
        @i >= @chars.size
      end

      private def peek : Char
        @chars[@i]
      end

      private def advance : Char
        c = @chars[@i]
        @i += 1
        if c == '\n'
          @line += 1
          @col = 1
        else
          @col += 1
        end
        c
      end
    end
  end
end
