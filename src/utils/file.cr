require "../monitor"
require "../config"
require "system/user"
require "system/group"
require "digest/md5"
require "digest/sha1"
require "digest/sha256"

## file.cr — file, directory and fifo checks: existence, ownership, mode,
## timestamps, size, checksum and content

module Jane
  module FileChecker
    extend self

    record FileStat,
      kind : Symbol, # :file, :directory, :fifo, :other
      size : Int64,
      inode : UInt64,
      mtime : Time,
      ctime : Time,
      atime : Time

    KIND_NAMES = {:file => "a regular file", :directory => "a directory", :fifo => "a fifo", :other => "a special file"}

    # Previous values for `changed` tests and checksum baselines, per check.
    @@last = {} of String => String
    @@checksum_cache = {} of String => Tuple(String, String) # key → {file signature, hash}

    def check_file(name : String, file_check : FileCheck) : Array(Monitor::Check)
      results = [] of Monitor::Check
      path = file_check.path
      prefix = file_check.prefix
      st = stat(path)

      wrong_kind = st && st.kind != file_check.kind
      ok = st && !wrong_kind
      message = if st.nil?
                  "'#{path}' not found"
                elsif wrong_kind
                  "'#{path}' is #{KIND_NAMES[st.kind]}, not #{KIND_NAMES[file_check.kind]}"
                else
                  "'#{path}' exists"
                end
      results << Monitor::Check.new(
        name: "#{prefix} #{name}",
        status: ok ? :ok : :alert,
        current: st.nil? ? "missing" : (wrong_kind ? st.kind.to_s : "exists"),
        threshold: "exists",
        message: message,
        policy: file_check.policies["exist"]? || Policy.new,
      )

      # Skip the other tests if the file doesn't exist (or is the wrong type)
      return results unless st && ok

      info = File.info(path)

      if expected_user = file_check.user
        actual_user = begin
          System::User.find_by(id: info.owner_id.to_s).username
        rescue
          info.owner_id.to_s
        end
        match = actual_user == expected_user
        results << Monitor::Check.new(
          name: "#{prefix} #{name} user",
          status: match ? :ok : :alert,
          current: actual_user,
          threshold: expected_user,
          message: match ? "'#{path}' owned by '#{expected_user}'" : "'#{path}' owned by '#{actual_user}', expected '#{expected_user}'",
          policy: file_check.policies["user"]? || Policy.new,
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
          name: "#{prefix} #{name} group",
          status: match ? :ok : :alert,
          current: actual_group,
          threshold: expected_group,
          message: match ? "'#{path}' group is '#{expected_group}'" : "'#{path}' group is '#{actual_group}', expected '#{expected_group}'",
          policy: file_check.policies["group"]? || Policy.new,
        )
      end

      if expected_mode = file_check.mode
        perms = info.permissions.value.to_i32
        actual_mode = "%o" % perms
        match = actual_mode == expected_mode
        results << Monitor::Check.new(
          name: "#{prefix} #{name} mode",
          status: match ? :ok : :alert,
          current: actual_mode,
          threshold: expected_mode,
          message: match ? "'#{path}' mode is #{expected_mode}" : "'#{path}' mode is #{actual_mode}, expected #{expected_mode}",
          policy: file_check.policies["mode"]? || Policy.new,
        )
      end

      file_check.rules.each do |rule|
        results << evaluate(name, file_check, rule, st)
      end

      results.concat(check_content(name, file_check))
      return results
    end

    private def evaluate(name : String, file_check : FileCheck, rule : FileRule, st : FileStat) : Monitor::Check
      check_name = "#{file_check.prefix} #{name} #{rule.label}"
      path = file_check.path

      case rule.test
      when "size"
        return changed_result(check_name, "#{name}:size", st.size.to_s, "Size", rule) if rule.op.changed?
        fired = Jane.compare(st.size.to_f64, rule.op, rule.value)
        current = Jane.format_size(st.size.to_f64)
        Monitor::Check.new(check_name, fired ? :alert : :ok, current, "#{Jane.op_symbol(rule.op)} #{Jane.format_size(rule.value)}",
          fired ? "'#{path}' size is #{current}" : "Within limits", policy: rule.policy)
      when "checksum"
        hash = begin
          checksum(name, path, rule.algorithm, st)
        rescue ex : File::Error | IO::Error
          return Monitor::Check.new(check_name, :alert, "unknown", rule.expect || "", "Cannot read '#{path}': #{ex.message}", policy: rule.policy)
        end
        return changed_result(check_name, "#{name}:#{rule.algorithm}", hash, "Checksum", rule) if rule.op.changed?
        # Without `expect`, compare against the hash seen when Jane started.
        expected = rule.expect.try(&.downcase) || (@@last["#{name}:#{rule.algorithm}:baseline"] ||= hash)
        fired = hash != expected
        Monitor::Check.new(check_name, fired ? :alert : :ok, short(hash), short(expected),
          fired ? "'#{path}' #{rule.algorithm} is #{hash}, expected #{expected}" : "Checksum matches", policy: rule.policy)
      else # timestamps
        time = case rule.test
               when "modify timestamp" then st.mtime
               when "change timestamp" then st.ctime
               when "access timestamp" then st.atime
               else                         st.mtime > st.ctime ? st.mtime : st.ctime
               end
        if rule.op.changed?
          return changed_result(check_name, "#{name}:#{rule.test}", time.to_unix_ns.to_s, rule.test.capitalize, rule,
            display: time.to_local.to_s("%Y-%m-%d %H:%M:%S"))
        end
        age = Math.max((Time.utc - time).total_seconds, 0.0)
        fired = Jane.compare(age, rule.op, rule.value)
        current = "#{Jane.format_duration(age)} ago"
        Monitor::Check.new(check_name, fired ? :alert : :ok, current, "#{Jane.op_symbol(rule.op)} #{Jane.format_duration(rule.value)}",
          fired ? "'#{path}' #{rule.test.sub("timestamp", "time")} was #{current} (#{time.to_local.to_s("%Y-%m-%d %H:%M:%S")})" : "Within limits",
          policy: rule.policy)
      end
    end

    # Fires in the cycle `value` differs from the previous cycle's value.
    private def changed_result(check_name : String, key : String, value : String, what : String, rule : FileRule,
                               display : String = value) : Monitor::Check
      prev = @@last[key]?
      @@last[key] = value
      changed = !prev.nil? && prev != value
      shown = what == "Checksum" ? short(display) : display
      Monitor::Check.new(check_name, changed ? :alert : :ok, shown, "unchanged",
        changed ? "#{what} changed" : "#{what} unchanged", policy: rule.policy)
    end

    # Hashes the file, reusing the previous hash while inode, size, mtime and
    # ctime are unchanged (large files aren't re-read every cycle).
    private def checksum(name : String, path : String, algorithm : String, st : FileStat) : String
      key = "#{name}:#{algorithm}"
      signature = "#{st.inode}:#{st.size}:#{st.mtime.to_unix_ns}:#{st.ctime.to_unix_ns}"
      if (cached = @@checksum_cache[key]?) && cached[0] == signature
        return cached[1]
      end
      digest = case algorithm
               when "sha1"   then Digest::SHA1.new
               when "sha256" then Digest::SHA256.new
               else               Digest::MD5.new
               end
      File.open(path) { |f| digest.update(f) }
      hash = digest.hexfinal
      @@checksum_cache[key] = {signature, hash}
      hash
    end

    private def short(hash : String) : String
      hash.size > 16 ? "#{hash[0, 12]}…" : hash
    end

    def stat(path : String) : FileStat?
      return nil unless LibC.stat(path.check_no_null_byte, out st) == 0
      kind = case st.st_mode & LibC::S_IFMT
             when LibC::S_IFREG then :file
             when LibC::S_IFDIR then :directory
             when LibC::S_IFIFO then :fifo
             else                    :other
             end
      FileStat.new(kind, st.st_size.to_i64, st.st_ino.to_u64, time(st.st_mtim), time(st.st_ctim), time(st.st_atim))
    end

    private def time(ts : LibC::Timespec) : Time
      Time.unix(ts.tv_sec.to_i64) + ts.tv_nsec.to_i64.nanoseconds
    end

    # Forget remembered values (specs).
    def reset : Nil
      @@last.clear
      @@checksum_cache.clear
    end

    # One result per content rule, evaluated on the lines appended since the
    # previous cycle (see ContentWatcher).
    private def check_content(name : String, file_check : FileCheck) : Array(Monitor::Check)
      return [] of Monitor::Check if file_check.content_rules.empty?
      lines = ContentWatcher.new_lines(name, file_check.path)

      file_check.content_rules.map do |rule|
        check_name = "File #{name} content #{rule.label}"
        if lines.nil?
          next Monitor::Check.new(check_name, :ok, "watching", rule.label,
            "Started watching '#{file_check.path}' at end of file", policy: rule.policy)
        end
        hits = lines.select { |l| rule.pattern.matches?(l) != rule.op.ne? }
        if hits.empty?
          Monitor::Check.new(check_name, :ok, "#{lines.size} new line(s)", rule.label,
            "No new lines #{rule.op.ne? ? "failing to match" : "matching"}", policy: rule.policy)
        else
          sample = hits.last.strip
          sample = sample[0, 200] + "…" if sample.size > 200
          Monitor::Check.new(check_name, :alert, "#{hits.size} line(s)", rule.label, sample, policy: rule.policy)
        end
      end
    end
  end
end
