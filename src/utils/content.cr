## content.cr — follows a file like `tail -f` for `if content = "..."` rules
##
## Like Monit, the first time a file is seen Jane starts at its end, so only
## lines written after Jane started are matched. Each later call returns the
## complete lines appended since the previous call. If the file was rotated
## (new inode) or truncated (smaller than our offset), reading restarts at the
## beginning of the new file.

module Jane
  module ContentWatcher
    extend self

    MAX_READ = 1024 * 1024 # bytes per check per cycle; the rest is read next cycle

    record Position, inode : UInt64, offset : Int64

    @@positions = {} of String => Position

    # Returns new complete lines, or nil the first time `key` is seen.
    def new_lines(key : String, path : String) : Array(String)?
      inode = inode_of(path)
      size = File.size(path).to_i64
      pos = @@positions[key]?

      if pos.nil?
        @@positions[key] = Position.new(inode, size)
        return nil
      end

      offset = pos.offset
      offset = 0_i64 if pos.inode != inode || size < offset
      if size == offset
        @@positions[key] = Position.new(inode, offset)
        return [] of String
      end

      length = Math.min(size - offset, MAX_READ.to_i64)
      bytes = Bytes.new(length)
      File.open(path) do |f|
        f.seek(offset)
        f.read_fully(bytes)
      end

      # Only consume up to the last newline; a partial line waits for the next cycle.
      last_nl = bytes.rindex('\n'.ord.to_u8)
      consumed = if last_nl
                   last_nl + 1
                 elsif length == MAX_READ
                   length # a single line longer than MAX_READ: take it in pieces
                 else
                   0
                 end
      @@positions[key] = Position.new(inode, offset + consumed)
      String.new(bytes[0, consumed]).lines
    end

    # Forget all positions (specs).
    def reset : Nil
      @@positions.clear
    end

    private def inode_of(path : String) : UInt64
      if LibC.stat(path.check_no_null_byte, out st) == 0
        st.st_ino.to_u64
      else
        0_u64
      end
    end
  end
end
