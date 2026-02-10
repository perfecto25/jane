require "hcl"
require "json"


# `value` is typically a Hash(String, HCL::Any) or HCL::Any
# Convert to a plain Crystal structure for JSON serialization
def to_plain(any : HCL::Any) : JSON::Any
  case raw = any.raw
  when Hash(String, HCL::Any)
    JSON::Any.new(
      raw.transform_values { |v| to_plain(v) }.to_h
    )
  when Array(HCL::Any)
    JSON::Any.new(raw.map { |v| to_plain(v) })
  when String
    JSON::Any.new(raw)
  when Int64
    JSON::Any.new(raw)
  when Float64
    JSON::Any.new(raw)
  when Bool
    JSON::Any.new(raw)
  when Nil
    JSON::Any.new(nil)
  else
    # Fallback: string representation
    JSON::Any.new(raw.to_s)
  end
end


begin
  path = "config.hcl"
  src = File.read(path)
  parser   = HCL::Parser.new(src, path: path)
  document = parser.parse!

  # Evaluate into Crystal-native data (Hash/String/Int/Bool/Array/etc.)
  value = document.evaluate

  
  json_any =
    case value
    when HCL::Any
      to_plain(value)
    when Hash(String, HCL::Any)
      JSON::Any.new(
        value.transform_values { |v| to_plain(v) }.to_h
      )
    else
      # If evaluate ever returns another type, just stringify
      JSON::Any.new(value.to_s)
    end

  puts json_any.to_pretty_json
rescue ex : HCL::ParseException
  STDERR.puts "HCL parse error in #{path}: #{ex.message}"
  exit 1
rescue ex
  STDERR.puts "Error: #{ex.message}"
  exit 1
end