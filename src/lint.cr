require "./config"

module Jane
  # jane -l FILE: checks the control file's syntax (via the real parser) and
  # its layout against the house style used by jane.conf:
  #   * top-level statements (set/include/check/comments) start in column 0
  #   * lines inside a check block are indented by exactly 4 spaces
  #   * check blocks are separated by exactly one blank line, with none inside
  #   * no tabs, trailing whitespace, CRLF, repeated spaces or leading/trailing
  #     blank lines; file ends with a single newline
  #   * keywords are lowercase
  module Lint
    record Issue, line : Int32, message : String

    INDENT = 4

    TOP_LEVEL = %w(check set include)
    MEMBER_WORDS = %w(if group tag every depends start stop restart timeout port path pidfile
      interface address matching with using and)
    # Words that need a value after them; ending a line on one means the
    # statement is split across lines.
    NEEDS_VALUE = %w(path pidfile interface address matching port timeout with using and every
      depends on group tag)

    def self.style_issues(text : String) : Array(Issue)
      issues = [] of Issue
      return issues if text.empty?

      issues << Issue.new(text.lines.size, "file must end with a newline") unless text.ends_with?("\n")
      issues << Issue.new(text.lines.size, "file ends with extra blank lines") if text.ends_with?("\n\n")

      # A check block runs from `check` until the next check/set/include, so
      # anything else that follows is a member, whether or not it is indented.
      in_block = false
      last_member = false # previous non-blank line belonged to the block
      prev_blank = false
      after_comment = false # previous non-blank line was a top-level comment
      blank_line = 0
      seen = false
      lines = text.split('\n')
      lines.pop if lines.last? == "" # artifact of the final newline

      lines.each_with_index do |raw, idx|
        n = idx + 1
        line = raw
        if line.ends_with?("\r")
          issues << Issue.new(n, "CRLF line ending")
          line = line.rchop
        end

        issues << Issue.new(n, "tab character (use spaces)") if line.includes?('\t')
        issues << Issue.new(n, "trailing whitespace") if line != line.rstrip && !line.strip.empty?

        if line.strip.empty?
          issues << Issue.new(n, "whitespace on blank line") unless line.empty?
          if prev_blank
            issues << Issue.new(n, "more than one consecutive blank line")
          elsif !seen
            issues << Issue.new(n, "blank line at start of file")
          else
            blank_line = n
          end
          prev_blank = true
          next
        end

        indent = line.starts_with?('\t') ? INDENT : line.size - line.lstrip(' ').size
        content = line.strip
        is_comment = content.starts_with?('#')
        word = content.split(/\s+/).first
        top = !is_comment && TOP_LEVEL.includes?(word.downcase)

        unless is_comment
          issues << Issue.new(n, "keyword '#{word}' must be lowercase") if word != word.downcase
          issues << Issue.new(n, "repeated spaces (use a single space)") if repeated_spaces?(content)
        end

        if !is_comment
          last = content.split(/\s+/).last.downcase
          if !top && !in_block
            issues << Issue.new(n, "expected 'check', 'set' or 'include', found '#{word}'")
          elsif !top && !MEMBER_WORDS.includes?(word.downcase)
            issues << Issue.new(n, "unknown keyword '#{word}' in check block (each statement must be on one line)")
          end
          if NEEDS_VALUE.includes?(last) && content.split(/\s+/).size > 1
            issues << Issue.new(n, "line ends with '#{last}' but no value follows on the same line")
          end
        end

        if top
          issues << Issue.new(n, "'#{word}' must start in column 0") if indent != 0
          need_blank = word.downcase == "check" ? !after_comment : last_member
          if seen && !prev_blank && need_blank
            issues << Issue.new(n, "expected a blank line before '#{word}'")
          end
          in_block = word.downcase == "check"
          last_member = in_block
          after_comment = false
        elsif is_comment
          member_comment = in_block && !prev_blank
          if member_comment
            issues << Issue.new(n, "check block lines must be indented #{INDENT} spaces (found #{indent})") if indent != INDENT
          else
            issues << Issue.new(n, "comment must start in column 0") if indent != 0
            issues << Issue.new(n, "expected a blank line before comment (end of check block)") if last_member && !prev_blank
            last_member = false
            after_comment = true
          end
          after_comment = false if member_comment
        elsif in_block
          after_comment = false
          if prev_blank && last_member
            issues << Issue.new(blank_line, "blank line inside check block")
          end
          issues << Issue.new(n, "check block lines must be indented #{INDENT} spaces (found #{indent})") if indent != INDENT
          last_member = true
        elsif indent != 0
          after_comment = false
          issues << Issue.new(n, "unexpected indentation outside a check block")
        end

        prev_blank = false
        seen = true
      end

      issues
    end

    # Rewrites text so that style_issues returns nothing. Syntax problems are
    # not touched.
    def self.fix(text : String) : String
      out = [] of String
      in_block = false
      last_member = false
      after_comment = false
      pending_blank = false

      text.split('\n').each do |raw|
        line = raw.rchop('\r').rstrip
        if line.empty?
          pending_blank = true unless out.empty?
          next
        end

        content = line.strip
        is_comment = content.starts_with?('#')
        indent = 0

        unless is_comment
          content = collapse_spaces(content)
          word = content.split(/\s+/).first
          content = word.downcase + content[word.size..]
        end
        word = content.split(/\s+/).first.downcase

        if !is_comment && TOP_LEVEL.includes?(word)
          need_blank = word == "check" ? !after_comment : last_member
          pending_blank = true if need_blank && !out.empty?
          in_block = word == "check"
          last_member = in_block
          after_comment = false
        elsif is_comment
          if in_block && !pending_blank
            indent = INDENT
            after_comment = false
          else
            pending_blank = true if last_member
            last_member = false
            after_comment = true
          end
        elsif in_block
          after_comment = false
          indent = INDENT
          pending_blank = false if last_member
          last_member = true
        end

        out << "" if pending_blank
        pending_blank = false
        out << (" " * indent) + content
      end

      out.empty? ? "" : out.join("\n") + "\n"
    end

    private def self.collapse_spaces(content : String) : String
      quote = nil
      prev_space = false
      String.build do |io|
        content.each_char do |c|
          if quote
            quote = nil if c == quote
            prev_space = false
          elsif c == '"' || c == '\''
            quote = c
            prev_space = false
          elsif c == ' '
            next if prev_space
            prev_space = true
          else
            prev_space = false
          end
          io << c
        end
      end
    end

    # True if the line has two or more consecutive spaces outside quotes.
    private def self.repeated_spaces?(content : String) : Bool
      quote = nil
      prev_space = false
      content.each_char do |c|
        if quote
          quote = nil if c == quote
          prev_space = false
        elsif c == '"' || c == '\''
          quote = c
          prev_space = false
        elsif c == ' '
          return true if prev_space
          prev_space = true
        else
          prev_space = false
        end
      end
      false
    end

    # Returns the process exit code: 0 clean, 1 if anything was reported.
    def self.run(path : String, fix : Bool = false) : Int32
      unless File.file?(path)
        STDERR.puts "Error: cannot read #{path}"
        return 1
      end

      if fix
        original = File.read(path)
        fixed = fix(original)
        if fixed != original
          File.write(path, fixed)
          puts "#{path}: fixed style issues"
        end
      end

      problems = 0
      begin
        _, warnings = Config.load(path)
        warnings.each do |w|
          puts "#{w} [warning]"
          problems += 1
        end
      rescue ex
        puts "#{path}: error: #{ex.message}"
        problems += 1
      end

      style_issues(File.read(path)).sort_by!(&.line).each do |i|
        puts "#{path}:#{i.line}: style: #{i.message}"
        problems += 1
      end

      if problems == 0
        puts "#{path}: OK"
        0
      else
        puts "#{problems} problem(s) found in #{path}"
        1
      end
    end
  end
end
