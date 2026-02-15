require "../monitor"
require "../config"
require "system/user"
require "system/group"

## file.cr — checks whether specific files exist and have expected ownership/mode

module Jane
  module FileChecker
    extend self

    def check_file(name : String, file_check : FileCheck) : Array(Monitor::Check)
      results = [] of Monitor::Check
      path = file_check.path
      found = File.exists?(path)

      results << Monitor::Check.new(
        name: "File #{name}",
        status: found ? :ok : :alert,
        current: found ? "exists" : "missing",
        threshold: "exists",
        message: found ? "'#{path}' exists" : "'#{path}' not found",
      )

      # Skip ownership/mode checks if the file doesn't exist
      return results unless found

      info = File.info(path)

      if expected_user = file_check.user
        actual_user = begin
          System::User.find_by(id: info.owner_id.to_s).username
        rescue
          info.owner_id.to_s
        end
        match = actual_user == expected_user
        results << Monitor::Check.new(
          name: "File #{name} user",
          status: match ? :ok : :alert,
          current: actual_user,
          threshold: expected_user,
          message: match ? "'#{path}' owned by '#{expected_user}'" : "'#{path}' owned by '#{actual_user}', expected '#{expected_user}'",
        )
      end

      if expected_group = file_check.group
        actual_group = begin
          System::Group.find_by(id: info.group_id.to_s).name
        rescue
          info.group_id.to_s
        end
        match = actual_group == expected_group
        results << Monitor::Check.new(
          name: "File #{name} group",
          status: match ? :ok : :alert,
          current: actual_group,
          threshold: expected_group,
          message: match ? "'#{path}' group is '#{expected_group}'" : "'#{path}' group is '#{actual_group}', expected '#{expected_group}'",
        )
      end

      if expected_mode = file_check.mode
        perms = info.permissions.value.to_i32
        actual_mode = "%o" % perms
        match = actual_mode == expected_mode
        results << Monitor::Check.new(
          name: "File #{name} mode",
          status: match ? :ok : :alert,
          current: actual_mode,
          threshold: expected_mode,
          message: match ? "'#{path}' mode is #{expected_mode}" : "'#{path}' mode is #{actual_mode}, expected #{expected_mode}",
        )
      end

      return results
    end
  end
end
