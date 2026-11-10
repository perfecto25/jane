## scheduler.cr — `every N cycles`
##
## A check with `every 15` runs on the first cycle and then on every 15th.
## In between, its last results are returned unchanged (the same objects), so
## the status table and HQ keep showing them and the Engine knows not to count
## them as a new evaluation.

module Jane
  class Scheduler
    getter cycle : Int64 = 0

    def initialize
      @cache = {} of String => Array(Monitor::Check)
      @last_run = {} of String => Int64
    end

    # Call once at the start of every daemon cycle.
    def tick : Nil
      @cycle += 1
    end

    def run(key : String, every : Int32, & : -> Array(Monitor::Check)) : Array(Monitor::Check)
      cached = @cache[key]?
      last = @last_run[key]?
      if cached && last && every > 1 && @cycle - last < every
        return cached
      end
      results = yield
      @cache[key] = results
      @last_run[key] = @cycle
      results
    end
  end
end
