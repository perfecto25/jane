#!/usr/bin/env crystal

# Simple Monit Config Parser
# No lexer, no complex grammar - just regex and string parsing!
# This is all you need for 95% of monitoring configs

require "json"

module SimpleMonit
  class Config
    property checks : Array(Check)

    def initialize
      @checks = [] of Check
    end

    def self.parse(content : String) : Config
      config = Config.new
      current_check : Check? = nil
      
      content.each_line do |line|
        line = line.strip
        
        # Skip empty lines and comments
        next if line.empty? || line.starts_with?('#')
        
        # Check statement (not indented)
        if line.starts_with?("check ") && !line.starts_with?("  ")
          current_check = parse_check_line(line)
          config.checks << current_check
        
        # Rules/config for current check (indented)
        elsif line.starts_with?("  ") && current_check
          parse_config_line(line.strip, current_check)
        end
      end
      
      config
    end

    def self.parse_check_line(line : String) : Check
      # Simple regex matching
      if match = line.match(/check\s+(\w+)\s+([\w\-\/\.]+)(?:\s+with\s+(.+))?/)
        type = match[1]
        name = match[2]
        with_clause = match[3]?
        
        check = Check.new(type, name)
        
        # Parse "with" clause
        if with_clause
          if path_match = with_clause.match(/path\s+(.+)/)
            check.path = path_match[1]
          elsif pidfile_match = with_clause.match(/pidfile\s+(.+)/)
            check.pidfile = pidfile_match[1]
          elsif address_match = with_clause.match(/address\s+(.+)/)
            check.address = address_match[1]
          end
        end
        
        check
      else
        raise "Cannot parse check line: #{line}"
      end
    end

    def self.parse_config_line(line : String, check : Check)
      # Start program
      if match = line.match(/start\s+program\s+=\s+"([^"]+)"(?:\s+with\s+timeout\s+(\d+)\s+seconds)?/)
        check.start_program = match[1]
        check.start_timeout = match[2]?.try(&.to_i)
      
      # Stop program
      elsif match = line.match(/stop\s+program\s+=\s+"([^"]+)"(?:\s+with\s+timeout\s+(\d+)\s+seconds)?/)
        check.stop_program = match[1]
        check.stop_timeout = match[2]?.try(&.to_i)
      
      # If statement
      elsif line.starts_with?("if ")
        rule = parse_if_line(line)
        check.rules << rule
      end
    end

    def self.parse_if_line(line : String) : Rule
      # Remove "if " and "then action"
      if match = line.match(/if\s+(.+)\s+then\s+(\w+)/)
        condition = match[1]
        action = match[2]
        
        rule = Rule.new(condition, action)
        
        # Extract cycles if present
        if cycles_match = condition.match(/for\s+(\d+)\s+cycles/)
          rule.cycles = cycles_match[1].to_i
        end
        
        if within_match = condition.match(/within\s+(\d+)\s+cycles/)
          rule.within_cycles = within_match[1].to_i
        end
        
        rule
      else
        raise "Cannot parse if line: #{line}"
      end
    end

    def to_s(io : IO)
      @checks.each do |check|
        io << check.to_s << "\n\n"
      end
    end
  end

  class Check
    property type : String
    property name : String
    property path : String?
    property pidfile : String?
    property address : String?
    property start_program : String?
    property start_timeout : Int32?
    property stop_program : String?
    property stop_timeout : Int32?
    property rules : Array(Rule)

    def initialize(@type, @name)
      @rules = [] of Rule
    end

    def to_s(io : IO)
      # Build check line
      io << "check #{@type} #{@name}"
      
      if path = @path
        io << " with path #{path}"
      elsif pidfile = @pidfile
        io << " with pidfile #{pidfile}"
      elsif address = @address
        io << " with address #{address}"
      end
      
      io << "\n"
      
      # Control programs
      if prog = @start_program
        io << "  start program = \"#{prog}\""
        io << " with timeout #{@start_timeout} seconds" if @start_timeout
        io << "\n"
      end
      
      if prog = @stop_program
        io << "  stop program = \"#{prog}\""
        io << " with timeout #{@stop_timeout} seconds" if @stop_timeout
        io << "\n"
      end
      
      # Rules
      @rules.each do |rule|
        io << "  " << rule.to_s << "\n"
      end
    end

    def to_h
      h = {
        "type" => @type,
        "name" => @name,
        "rules" => @rules.map(&.to_h)
      } of String => String | Array(Hash(String, String | Int32 | Nil))
      
      h["path"] = @path.not_nil! if @path.not_nil!
      h["pidfile"] = @pidfile.not_nil! if @pidfile
      h["address"] = @address.not_nil! if @address
      h["start_program"] = @start_program.not_nil! if @start_program
      h["start_timeout"] = @start_timeout.not_nil! if @start_timeout
      h["stop_program"] = @stop_program.not_nil! if @stop_program
      h["stop_timeout"] = @stop_timeout.not_nil! if @stop_timeout
      
      h
    end
  end

  class Rule
    property condition : String
    property action : String
    property cycles : Int32?
    property within_cycles : Int32?

    def initialize(@condition, @action)
    end

    def to_s(io : IO)
      io << "if #{@condition} then #{@action}"
    end

    def to_h
      h = {
        "condition" => @condition,
        "action" => @action
      } of String => String | Int32 | Nil
      
      h["cycles"] = @cycles if @cycles
      h["within_cycles"] = @within_cycles if @within_cycles
      
      h
    end
  end
end

# ============================================================================
# Example Usage
# ============================================================================
