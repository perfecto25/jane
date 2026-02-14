require "json"

module Jane
  module State
    extend self

    def path(config_path : String) : String
      File.join(File.dirname(config_path), "state.json")
    end

    def load(config_path : String) : Hash(String, JSON::Any)
      p = path(config_path)
      return default_state unless File.exists?(p)
      parsed = JSON.parse(File.read(p))
      parsed.as_h
    rescue
      default_state
    end

    def save(config_path : String, unmonitored_tags : Array(String))
      p = path(config_path)
      data = {"unmonitored_tags" => unmonitored_tags}
      File.write(p, data.to_json)
    end

    def unmonitored_tags(config_path : String) : Array(String)
      state = load(config_path)
      if tags = state["unmonitored_tags"]?
        tags.as_a.map(&.as_s)
      else
        [] of String
      end
    end

    private def default_state : Hash(String, JSON::Any)
      parsed = JSON.parse(%({"unmonitored_tags": []}))
      parsed.as_h
    end
  end
end
