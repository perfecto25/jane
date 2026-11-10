require "spec"
require "file_utils"
require "../src/config"
require "../src/monitor"

private alias Check = Jane::Monitor::Check

private def result(status : Symbol, policy = Jane::Policy.new, name = "Process web") : Check
  Check.new(name, status, status == :alert ? "not found" : "running", "running", "raw #{status}", policy: policy)
end

# Runs an engine over a sequence of raw statuses. Returns the output statuses
# and the (reason, commands) of every action it triggered.
private def run_engine(statuses : Array(Symbol), policy : Jane::Policy)
  actions = [] of Tuple(String, Array(String))
  engine = Jane::Engine.new(->(_name : String, cmds : Array(String), reason : String) { actions << {reason, cmds}; nil })
  out = statuses.map { |s| engine.process([result(s, policy)]).first.status }
  {out, actions}
end

describe Jane::Engine do
  it "passes results through unchanged with the default policy" do
    out, actions = run_engine([:ok, :alert, :alert, :ok], Jane::Policy.new)
    out.should eq ["ok", "alert", "alert", "ok"]
    actions.should be_empty
  end

  it "alerts only after N consecutive failures with 'for N cycles'" do
    out, _ = run_engine([:alert, :alert, :ok, :alert, :alert, :alert, :ok], Jane::Policy.new(times: 3, cycles: 3))
    out.should eq ["ok", "ok", "ok", "ok", "ok", "alert", "ok"]
  end

  it "alerts on 'N times within M cycles' and stays in alert until the window drains" do
    policy = Jane::Policy.new(times: 2, cycles: 4)
    out, _ = run_engine([:alert, :ok, :alert, :ok, :ok, :ok, :ok], policy)
    # failures in window: 1, 1, 2*, 2*, 1 (first one left the window), 0, 0
    out.should eq ["ok", "ok", "alert", "alert", "ok", "ok", "ok"]
  end

  it "explains unconfirmed and lingering states in the message" do
    engine = Jane::Engine.new(->(_n : String, _c : Array(String), _r : String) { nil })
    policy = Jane::Policy.new(times: 2, cycles: 3)
    engine.process([result(:alert, policy)]).first.message.should contain "1 of 2 failures, 2 times within 3 cycles; not alerting yet"
    engine.process([result(:alert, policy)]).first.status.should eq "alert"
    engine.process([result(:ok, policy)]).first.message.should contain "still alerting: 2 failures in the last 3 cycles"
  end

  it "runs commands on failure, on repeat, and on recovery" do
    policy = Jane::Policy.new(action: "exec", commands: ["fix"], repeat: 2, recovery_commands: ["notify"])
    _, actions = run_engine([:ok, :alert, :alert, :alert, :alert, :ok, :ok], policy)
    actions.should eq [
      {"exec", ["fix"]},          # ok → failing
      {"exec (repeat)", ["fix"]}, # 2 cycles later
      {"recovered", ["notify"]},
    ]
  end

  it "does not re-evaluate results the scheduler reused" do
    actions = [] of String
    engine = Jane::Engine.new(->(_n : String, _c : Array(String), reason : String) { actions << reason; nil })
    policy = Jane::Policy.new(times: 2, cycles: 2, commands: ["fix"])
    same = result(:alert, policy)
    3.times { engine.process([same]).first.status.should eq "ok" } # counted once
    engine.process([result(:alert, policy)]).first.status.should eq "alert"
    actions.should eq ["alert"]
  end
end

describe Jane::Scheduler do
  it "runs a check on the first cycle and then every N cycles, reusing results in between" do
    scheduler = Jane::Scheduler.new
    runs = [] of Int64
    6.times do
      scheduler.tick
      scheduler.run("program:x", 3) { runs << scheduler.cycle; [result(:ok)] }
    end
    runs.should eq [1_i64, 4_i64]
  end

  it "returns the same result objects between runs" do
    scheduler = Jane::Scheduler.new
    scheduler.tick
    first = scheduler.run("k", 2) { [result(:ok)] }
    scheduler.tick
    scheduler.run("k", 2) { [result(:alert)] }.first.same?(first.first).should be_true
  end
end

describe Jane::Shell do
  it "captures output and exit status" do
    r = Jane::Shell.run("echo hello; echo oops >&2; exit 3", 5.seconds)
    r.exit_code.should eq 3
    r.output.should contain "hello"
    r.output.should contain "oops"
    r.timed_out.should be_false
  end

  it "kills commands that time out" do
    r = nil
    elapsed = Time.measure { r = Jane::Shell.run("sleep 10", 300.milliseconds) }
    r.not_nil!.timed_out.should be_true
    elapsed.should be < 3.seconds
  end
end

describe Jane::ProgramChecker do
  it "evaluates status and content rules on one run" do
    rules = [
      Jane::ProgramRule.new("status", Jane::Conf::Op::NE, number: 0.0),
      Jane::ProgramRule.new("content", Jane::Conf::Op::NE, pattern: /^ok$/),
    ]
    prog = Jane::ProgramCheck.new("echo degraded; exit 2", 5, rules)
    res = Jane::ProgramChecker.check_program("risk", prog, 10)
    res.map(&.name).should eq [%(Program risk status != 0), %(Program risk content != "^ok$")]
    res.map(&.status).should eq ["alert", "alert"]

    ok = Jane::ProgramChecker.check_program("risk", Jane::ProgramCheck.new("echo ok", 5, rules), 10)
    ok.map(&.status).should eq ["ok", "ok"]
  end

  it "alerts when the program times out" do
    prog = Jane::ProgramCheck.new("sleep 10", 1, [Jane::ProgramRule.new("status", Jane::Conf::Op::NE, number: 0.0)])
    res = Jane::ProgramChecker.check_program("slow", prog, 10)
    res.size.should eq 1
    {res.first.name, res.first.status, res.first.current}.should eq({"Program slow", "alert", "timed out"})
  end
end

describe Jane::ContentWatcher do
  it "starts at end of file, returns appended lines, and handles rotation" do
    Jane::ContentWatcher.reset
    dir = File.tempname("jane-content")
    Dir.mkdir_p(dir)
    path = File.join(dir, "messages")
    begin
      File.write(path, "old line\n")
      Jane::ContentWatcher.new_lines("k", path).should be_nil
      Jane::ContentWatcher.new_lines("k", path).should eq [] of String

      File.open(path, "a") { |f| f << "kernel: BUG one\npartial" }
      Jane::ContentWatcher.new_lines("k", path).should eq ["kernel: BUG one"]
      File.open(path, "a") { |f| f << " line\n" }
      Jane::ContentWatcher.new_lines("k", path).should eq ["partial line"]

      # rotate: new file with a new inode
      File.rename(path, path + ".1")
      File.write(path, "fresh\n")
      Jane::ContentWatcher.new_lines("k", path).should eq ["fresh"]
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "feeds file content rules" do
    Jane::ContentWatcher.reset
    dir = File.tempname("jane-content")
    Dir.mkdir_p(dir)
    path = File.join(dir, "log")
    begin
      File.write(path, "")
      file = Jane::FileCheck.new(path)
      file.content_rules << Jane::ContentRule.new(Jane::Conf::Op::EQ, /Out of memory/)
      name = %(File log content = "Out of memory")

      first = Jane::FileChecker.check_file("log", file).find! { |c| c.name == name }
      first.status.should eq "ok"
      File.open(path, "a") { |f| f << "all good\nkernel: Out of memory: killed 123\n" }
      hit = Jane::FileChecker.check_file("log", file).find! { |c| c.name == name }
      {hit.status, hit.current, hit.message}.should eq({"alert", "1 line(s)", "kernel: Out of memory: killed 123"})
      Jane::FileChecker.check_file("log", file).find! { |c| c.name == name }.status.should eq "ok"
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

# Starts `sh -c "<script>"` with a unique marker in its command line so
# `matching` finds exactly this process.
private def spawn_marked(script : String) : Tuple(Process, String)
  marker = "jane-spec-#{Random.rand(1_000_000_000)}"
  {Process.new("sh", ["-c", "#{script} # #{marker}"]), marker}
end

private def process_check(marker : String, rules : Array(Jane::ProcessRule)) : Jane::ProcessCheck
  check = Jane::ProcessCheck.new(nil, marker, nil)
  check.rules = rules
  check
end

private def by_name(results : Array(Check), name : String) : Check
  results.find { |c| c.name == name } || raise "no result named #{name.inspect} in #{results.map(&.name)}"
end

describe Jane::ProcTable do
  it "reads this process and builds process trees" do
    Jane::ProcTable.reset
    proc, _ = spawn_marked("sleep 30 & sleep 30; wait")
    begin
      sleep 200.milliseconds
      snap = Jane::ProcTable.rescan
      own = snap.entries[Process.pid.to_i32]
      own.rss.should be > 0
      own.threads.should be >= 1
      tree = snap.tree(proc.pid.to_i32)
      tree.first.should eq proc.pid.to_i32
      tree.size.should eq 3 # sh + 2 sleeps
      Jane::ProcTable.uptime_of(snap.entries[proc.pid.to_i32]).should be < 60
    ensure
      proc.terminate(graceful: false) rescue nil
    end
  end

  it "measures CPU of a busy process" do
    Jane::ProcTable.reset
    proc, _ = spawn_marked("while :; do :; done")
    begin
      sleep 300.milliseconds
      Jane::ProcTable.rescan
      sleep 300.milliseconds
      pct = Jane::ProcTable.cpu_percent([proc.pid.to_i32])
      # One busy core out of N: about 100/N percent.
      pct.should be > 100.0 / System.cpu_count / 3
      pct.should be <= 100.0
    ensure
      proc.terminate(graceful: false) rescue nil
    end
  end
end

describe "ProcessChecker resource rules" do
  it "evaluates memory, threads, children and uptime on the matched process" do
    Jane::ProcTable.reset
    proc, marker = spawn_marked("sleep 30 & sleep 30 & wait")
    begin
      sleep 200.milliseconds
      rules = [
        Jane::ProcessRule.new("memory", Jane::Conf::Op::GT, 1.0, :bytes),
        Jane::ProcessRule.new("total memory", Jane::Conf::Op::GT, 1024.0 ** 4, :bytes),
        Jane::ProcessRule.new("threads", Jane::Conf::Op::GT, 10.0),
        Jane::ProcessRule.new("children", Jane::Conf::Op::GE, 2.0),
        Jane::ProcessRule.new("uptime", Jane::Conf::Op::LT, 3600.0, :seconds),
      ]
      res = Jane::ProcessChecker.check_process("spec", process_check(marker, rules))
      by_name(res, "Process spec").status.should eq "ok"
      by_name(res, "Process spec memory > 1.00 B").status.should eq "alert"
      by_name(res, "Process spec total memory > 1.00 TB").status.should eq "ok"
      by_name(res, "Process spec threads > 10").status.should eq "ok"
      children = by_name(res, "Process spec children >= 2")
      {children.status, children.current}.should eq({"alert", "2"})
      by_name(res, "Process spec uptime < 1h").status.should eq "alert"
    ensure
      proc.terminate(graceful: false) rescue nil
    end
  end

  it "skips resource rules when the process isn't running" do
    rules = [Jane::ProcessRule.new("threads", Jane::Conf::Op::GT, 10.0)]
    res = Jane::ProcessChecker.check_process("gone", process_check("jane-spec-no-such-process-#{Random.rand(1_000_000)}", rules))
    res.map(&.name).should eq ["Process gone"]
    res.first.status.should eq "alert"
  end

  it "detects a changed pid once, in the cycle it changes" do
    marker = "jane-spec-#{Random.rand(1_000_000_000)}"
    rules = [Jane::ProcessRule.new("pid", Jane::Conf::Op::Changed)]
    check = process_check(marker, rules)
    name = "Process restart pid changed"
    first = Process.new("sh", ["-c", "sleep 30; : # #{marker}"])
    begin
      sleep 100.milliseconds
      by_name(Jane::ProcessChecker.check_process("restart", check), name).status.should eq "ok"
      by_name(Jane::ProcessChecker.check_process("restart", check), name).status.should eq "ok"
    ensure
      first.terminate(graceful: false) rescue nil
      first.wait rescue nil
    end
    second = Process.new("sh", ["-c", "sleep 30; : # #{marker}"])
    begin
      sleep 100.milliseconds
      changed = by_name(Jane::ProcessChecker.check_process("restart", check), name)
      changed.status.should eq "alert"
      changed.message.should eq "PID changed from #{first.pid} to #{second.pid}"
      by_name(Jane::ProcessChecker.check_process("restart", check), name).status.should eq "ok"
    ensure
      second.terminate(graceful: false) rescue nil
    end
  end
end

describe "port checks" do
  it "accepts servers that never send a banner, and checks expect patterns" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    spawn do
      while client = server.accept?
        client.puts "SSH-2.0-spec" if client.local_address.port == port && ENV["JANE_SPEC_BANNER"]? == "1"
        sleep 50.milliseconds
        client.close
      end
    end
    begin
      ok, _ = Jane::Network::Connection.port_check("127.0.0.1", port, 1)
      ok.should be_true

      ENV["JANE_SPEC_BANNER"] = "1"
      ok, _ = Jane::Network::Connection.port_check("127.0.0.1", port, 1, /^SSH-/)
      ok.should be_true
      ok, msg = Jane::Network::Connection.port_check("127.0.0.1", port, 1, /^HTTP/)
      ok.should be_false
      msg.should contain %(answered "SSH-2.0-spec")
    ensure
      ENV.delete("JANE_SPEC_BANNER")
      server.close
    end
    closed, msg = Jane::Network::Connection.port_check("127.0.0.1", port, 1)
    closed.should be_false
    msg.should contain "Cannot connect"
  end
end

describe "Monitor.perform_checks policies" do
  it "keeps each process rule's own policy next to the existence policy" do
    proc, marker = spawn_marked("sleep 30; :")
    begin
      sleep 100.milliseconds
      check = process_check(marker, [Jane::ProcessRule.new("pid", Jane::Conf::Op::Changed, policy: Jane::Policy.new(commands: ["notify"]))])
      check.policy = Jane::Policy.new(times: 2, cycles: 2, action: "restart", commands: ["stop", "start"])
      checks = Jane::CheckConfig.new(nil, nil, {} of String => Jane::FilesystemCheck, {} of String => Jane::InterfaceCheck,
        {} of String => Jane::ConnectionCheck, {} of String => Jane::BandwidthCheck,
        {"app" => check}, {} of String => Jane::FileCheck)
      config = Jane::Config.new(Jane::LogConfig.new("syslog", nil, "info"), checks, Jane::DefaultsConfig.new)
      results = Jane::Monitor.perform_checks(config)
      by_name(results, "Process app").policy.commands.should eq ["stop", "start"]
      by_name(results, "Process app pid changed").policy.commands.should eq ["notify"]
    ensure
      proc.terminate(graceful: false) rescue nil
    end
  end
end

describe "process disk I/O" do
  it "measures write operations of a process tree" do
    Jane::ProcTable.reset
    # The loop runs in a subshell, so only the total includes it.
    proc, marker = spawn_marked("while :; do echo x; done > /dev/null; :")
    begin
      sleep 200.milliseconds
      rules = [
        Jane::ProcessRule.new("total disk write", Jane::Conf::Op::GT, 100.0, :ops_rate),
        Jane::ProcessRule.new("disk write", Jane::Conf::Op::GT, 1_000_000_000.0, :ops_rate),
      ]
      res = Jane::ProcessChecker.check_process("io", process_check(marker, rules))
      total = by_name(res, "Process io total disk write > 100 ops/s")
      total.status.should eq "alert"
      total.current.should end_with "ops/s"
      by_name(res, "Process io disk write > 1000000000 ops/s").status.should eq "ok"
    ensure
      proc.terminate(graceful: false) rescue nil
      Process.run("pkill", ["-f", marker]) rescue nil
    end
  end

  it "reuses samples for several rules in one cycle" do
    Jane::ProcTable.reset
    pid = Process.pid.to_i32
    first = Jane::ProcTable.io_rate([pid])
    elapsed = Time.measure { Jane::ProcTable.io_rate([pid]).should eq first }
    elapsed.should be < 50.milliseconds # no second 100 ms baseline
  end

  it "reports processes whose io it can't read" do
    next if LibC.getuid == 0
    Jane::ProcTable.reset
    expect_raises(Jane::ProcTable::IOAccessError, /permission denied/) { Jane::ProcTable.io_rate([1]) }
  end
end

private def with_temp_dir(&)
  dir = File.tempname("jane-file")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def file_check(path : String, rules : Array(Jane::FileRule), kind = :file) : Jane::FileCheck
  check = Jane::FileCheck.new(path)
  check.kind = kind
  check.rules = rules
  check
end

describe "file timestamp, size and checksum tests" do

  it "measures the age of the modify time" do
    Jane::FileChecker.reset
    with_temp_dir do |dir|
      path = File.join(dir, "hb")
      File.write(path, "x")
      File.touch(path, Time.utc - 10.minutes)
      rules = [Jane::FileRule.new("modify timestamp", Jane::Conf::Op::GT, 300.0), Jane::FileRule.new("modify timestamp", Jane::Conf::Op::GT, 3600.0)]
      res = Jane::FileChecker.check_file("hb", file_check(path, rules))
      stale = by_name(res, "File hb modify timestamp > 5m")
      {stale.status, stale.current}.should eq({"alert", "10m ago"})
      by_name(res, "File hb modify timestamp > 1h").status.should eq "ok"
    end
  end

  it "fires changed tests once, in the cycle the value changes" do
    Jane::FileChecker.reset
    with_temp_dir do |dir|
      path = File.join(dir, "f")
      File.write(path, "one")
      rules = [Jane::FileRule.new("size", Jane::Conf::Op::Changed), Jane::FileRule.new("checksum", Jane::Conf::Op::Changed, algorithm: "sha1")]
      check = file_check(path, rules)
      statuses = -> {
        res = Jane::FileChecker.check_file("f", check)
        {by_name(res, "File f size changed").status, by_name(res, "File f sha1 checksum changed").status}
      }
      statuses.call.should eq({"ok", "ok"}) # first cycle: nothing to compare with
      statuses.call.should eq({"ok", "ok"})
      File.write(path, "two") # same size, different content
      statuses.call.should eq({"ok", "alert"})
      statuses.call.should eq({"ok", "ok"})
      File.write(path, "three")
      statuses.call.should eq({"alert", "alert"})
    end
  end

  it "compares checksums with an expected hash, or with the hash at startup" do
    Jane::FileChecker.reset
    with_temp_dir do |dir|
      path = File.join(dir, "conf")
      File.write(path, "")
      rules = [
        Jane::FileRule.new("checksum", Jane::Conf::Op::NE, algorithm: "md5", expect: "d41d8cd98f00b204e9800998ecf8427e"),
        Jane::FileRule.new("checksum", Jane::Conf::Op::NE, algorithm: "sha256"),
      ]
      check = file_check(path, rules)
      res = Jane::FileChecker.check_file("conf", check)
      by_name(res, "File conf md5 checksum").status.should eq "ok"
      by_name(res, "File conf sha256 checksum").status.should eq "ok"

      File.write(path, "tampered")
      2.times do # stays failed while the content differs
        res = Jane::FileChecker.check_file("conf", check)
        by_name(res, "File conf md5 checksum").status.should eq "alert"
        by_name(res, "File conf sha256 checksum").status.should eq "alert"
      end
      File.write(path, "")
      res = Jane::FileChecker.check_file("conf", check)
      by_name(res, "File conf sha256 checksum").status.should eq "ok"
    end
  end

  it "checks directories and fifos by type" do
    Jane::FileChecker.reset
    with_temp_dir do |dir|
      Process.run("mkfifo", [File.join(dir, "pipe")])
      Jane::FileChecker.check_file("d", file_check(dir, [] of Jane::FileRule, :directory)).first.status.should eq "ok"
      Jane::FileChecker.check_file("p", file_check(File.join(dir, "pipe"), [] of Jane::FileRule, :fifo)).first.status.should eq "ok"
      wrong = Jane::FileChecker.check_file("f", file_check(dir, [] of Jane::FileRule, :file)).first
      {wrong.name, wrong.status, wrong.message}.should eq({"File f", "alert", "'#{dir}' is a directory, not a regular file"})
      # a plain FileCheck expects a regular file
      Jane::FileChecker.check_file("dflt", Jane::FileCheck.new(dir)).first.status.should eq "alert"
    end
  end
end

require "http/server"

private def start_http(handler : HTTP::Handler::HandlerProc, tls : OpenSSL::SSL::Context::Server? = nil) : Tuple(HTTP::Server, Int32)
  server = HTTP::Server.new(handler)
  address = tls ? server.bind_tls("127.0.0.1", 0, tls) : server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  {server, address.port}
end

private def probe_for(port : Int32, &) : Jane::PortProbe
  p = Jane::PortProbe.new("127.0.0.1", port)
  p.http = true
  yield p
  p
end

describe "HTTP probes" do
  it "checks status, content, request path and host header" do
    seen_host = Channel(String).new(10)
    server, port = start_http(->(ctx : HTTP::Server::Context) {
      seen_host.send(ctx.request.headers["Host"]? || "")
      case ctx.request.resource
      when "/health" then ctx.response.print "status: healthy"
      when "/boom"   then ctx.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
      else                ctx.response.status = HTTP::Status::NOT_FOUND
      end
      nil
    })
    begin
      run = ->(p : Jane::PortProbe) { Jane::Network::Connection.probe(p, 2) }

      ok = run.call(probe_for(port) { |p| p.request = "/health"; p.content = /healthy/; p.content_op = Jane::Conf::Op::EQ })
      {ok.ok, ok.current}.should eq({true, "200 OK"})
      seen_host.receive.should eq "127.0.0.1:#{port}"

      run.call(probe_for(port) { |p| p.request = "/health"; p.host_header = "api.example.com" }).ok.should be_true
      seen_host.receive.should eq "api.example.com"

      missing = run.call(probe_for(port) { |p| p.request = "/nope" })
      {missing.ok, missing.current}.should eq({false, "404 Not Found"})
      missing.message.should contain "required status < 400"
      seen_host.receive

      # explicit status: 500 is fine when "status < 600" is all we ask
      run.call(probe_for(port) { |p| p.request = "/boom"; p.status_op = Jane::Conf::Op::LT; p.status = 600 }).ok.should be_true
      seen_host.receive

      bad_content = run.call(probe_for(port) { |p| p.request = "/health"; p.content = /healthy/; p.content_op = Jane::Conf::Op::NE })
      bad_content.ok.should be_false
      bad_content.message.should contain %(content matches "healthy")
    ensure
      server.close
    end
  end

  it "reports servers that close without an HTTP response" do
    tcp = TCPServer.new("127.0.0.1", 0)
    spawn { while c = tcp.accept?; c.close; end }
    begin
      r = Jane::Network::Connection.probe(probe_for(tcp.local_address.port) { }, 2)
      r.ok.should be_false
    ensure
      tcp.close
    end
  end
end

private def tls_probe(port : Int32, &) : Jane::Network::Connection::ProbeResult
  p = Jane::PortProbe.new("127.0.0.1", port)
  p.ssl = true
  yield p
  Jane::Network::Connection.probe(p, 2)
end

describe "TLS probes" do
  it "checks certificate expiry and verification" do
    if Process.find_executable("openssl").nil?
      pending!("openssl CLI not installed")
    end
    with_temp_dir do |dir|
      key, cert = File.join(dir, "key.pem"), File.join(dir, "cert.pem")
      Process.run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                              "-days", "10", "-subj", "/CN=jane-spec.local"]).success?.should be_true
      ctx = OpenSSL::SSL::Context::Server.new
      ctx.certificate_chain = cert
      ctx.private_key = key
      server, port = start_http(->(c : HTTP::Server::Context) { c.response.print "secure"; nil }, ctx)
      begin
        good = tls_probe(port) { |p| p.cert_op = Jane::Conf::Op::GT; p.cert_days = 5.0 }
        good.ok.should be_true
        good.current.should match /\Aopen, cert (9|10)d\z/ # 10 days minus the seconds since the cert was made

        expiring = tls_probe(port) { |p| p.cert_op = Jane::Conf::Op::GT; p.cert_days = 30.0 }
        expiring.ok.should be_false
        expiring.message.should match /\(CN=jane-spec\.local\) expires in (9|10) days/

        https = tls_probe(port) { |p| p.http = true; p.content = /secure/; p.content_op = Jane::Conf::Op::EQ; p.cert_op = Jane::Conf::Op::GT; p.cert_days = 1.0 }
        https.ok.should be_true
        https.current.should match /\A200 OK, cert (9|10)d\z/

        verified = tls_probe(port) { |p| p.verify = true }
        {verified.ok, verified.current}.should eq({false, "tls error"})
        verified.message.should contain "certificate verify failed"
      ensure
        server.close
      end
    end
  end
end

describe Jane::Filesystem do
  entries = [
    Jane::Filesystem::MountEntry.new("/dev/sda2", "/", "ext4", "rw,relatime"),
    Jane::Filesystem::MountEntry.new("/dev/sdb1", "/mnt/data", "xfs", "rw"),
    Jane::Filesystem::MountEntry.new("server:/export", "/mnt/data", "nfs4", "ro"), # mounted over /mnt/data
    Jane::Filesystem::MountEntry.new("/dev/sdc1", "/mnt/my disk", "ext4", "rw"),
  ]

  it "finds mounts by mount point or device; the last mount at a path wins" do
    Jane::Filesystem.find_mount("/", entries).try(&.device).should eq "/dev/sda2"
    Jane::Filesystem.find_mount("/mnt/data/", entries).try(&.device).should eq "server:/export"
    Jane::Filesystem.find_mount("/dev/sdb1", entries).try(&.mount_point).should eq "/mnt/data"
    Jane::Filesystem.find_mount("/mnt/my disk", entries).try(&.device).should eq "/dev/sdc1"
    Jane::Filesystem.find_mount("/mnt/data/sub", entries).should be_nil
  end

  it "reads space and inode usage" do
    u = Jane::Filesystem.usage("/", 5)
    u.should be_a(Jane::Filesystem::Usage)
    u = u.as(Jane::Filesystem::Usage)
    u.total.should be > 0
    (0.0..100.0).should contain(u.usage_pct)
    u.free.should be <= u.total
  end

  it "alerts when the path is missing or not a mount point" do
    with_temp_dir do |dir|
      fs = Jane::FilesystemCheck.new(dir, [Jane::Threshold.new(99.0, :percent)])
      res = Jane::Filesystem.check_filesystem("x", fs)
      {res.size, res.first.name, res.first.status, res.first.current}.should eq({1, "Filesystem x", "alert", "not mounted"})

      gone = Jane::FilesystemCheck.new(File.join(dir, "nope"), [Jane::Threshold.new(99.0, :percent)])
      missing = Jane::Filesystem.check_filesystem("y", gone)
      {missing.first.status, missing.first.current, missing.first.message}.should eq({"alert", "missing", "'#{File.join(dir, "nope")}' not found"})

      # a mount point works
      Jane::Filesystem.check_filesystem("r", Jane::FilesystemCheck.new("/", [Jane::Threshold.new(99.9, :percent)])).first.current.should_not eq "not mounted"
    end
  end

  it "doesn't hang on a filesystem that never answers" do
    with_temp_dir do |dir|
      # A fake `stat` that hangs like statvfs on a dead NFS server.
      File.write(File.join(dir, "stat"), "#!/bin/sh\nsleep 30\n")
      File.chmod(File.join(dir, "stat"), 0o755)
      old_path = ENV["PATH"]
      ENV["PATH"] = "#{dir}:#{old_path}"
      begin
        r = nil
        elapsed = Time.measure { r = Jane::Filesystem.usage("/", 1) }
        elapsed.should be < 5.seconds
        r.as(String).should contain "did not respond within 1s"
      ensure
        ENV["PATH"] = old_path
      end
    end
  end
end

private def build_system(src : String) : Tuple(Jane::Config, Array(String))
  parser = Jane::Conf::Parser.parse_string(src, "test.conf")
  builder = Jane::Conf::Builder.new(parser.document, parser.warnings)
  {builder.build, builder.warnings.map { |pos, msg| "#{pos}: #{msg}" }}
end

describe "system swap and per-core load" do
  it "produces swap and per-core load results" do
    config, _ = build_system(<<-CONF)
      check system h
          if loadavg (5min) per core > 1000 then alert
          if loadavg (5min) per core > 0 then alert
          if swap usage > 100 % then alert
      CONF
    cpu = Jane::Cpu.check_cpu(config.check.cpu.not_nil!)
    cpu.map(&.name).should eq ["Load Avg (5min) per core >0", "Load Avg (5min) per core >1000"]
    cpu.map(&.status).should eq ["alert", "ok"] unless File.read("/proc/loadavg").split[1].to_f == 0
    swap = Jane::Memory.check_memory(config.check.memory.not_nil!)
    swap.size.should eq 1
    swap[0].name.should eq "Swap Usage"
    swap[0].status.should eq "ok"
  end
end

private def level_rows(base : String, values : Array(Float64), current : Float64) : Array(Check)
  levels = values.map { |v| Jane::Threshold.new(v, :bytes) }
  levels.map do |t|
    Jane::Monitor.level_check(base, t, levels, current > t.value ? :alert : :ok, current.to_s, t.value.to_s, "m")
  end
end

describe "Monitor.collapse_levels" do
  it "shows one row per check: the highest level in alert" do
    rows = Jane::Monitor.collapse_levels(level_rows("Memory Usage", [100.0, 200.0, 300.0], 150.0))
    rows.map { |r| {r.name, r.status, r.threshold} }.should eq [{"Memory Usage", "alert", "100.0"}]
    rows = Jane::Monitor.collapse_levels(level_rows("Memory Usage", [300.0, 100.0, 200.0], 999.0))
    rows.map { |r| {r.name, r.status, r.threshold} }.should eq [{"Memory Usage", "alert", "300.0"}]
  end

  it "shows the lowest level when nothing alerts, and keeps other rows in place" do
    other = Check.new("CPU Usage", :ok, "1%", "90%", "Within limits")
    rows = Jane::Monitor.collapse_levels([other] + level_rows("Swap Usage", [100.0, 200.0], 50.0) + [other])
    rows.map { |r| {r.name, r.status, r.threshold} }.should eq [
      {"CPU Usage", "ok", "90%"}, {"Swap Usage", "ok", "100.0"}, {"CPU Usage", "ok", "90%"},
    ]
  end

  it "uses the engine's status, so a level waiting on 'for N cycles' isn't shown" do
    rows = level_rows("Memory Usage", [100.0, 200.0], 250.0)
    rows[1] = rows[1].with_status(:ok, "not alerting yet")
    Jane::Monitor.collapse_levels(rows).map(&.threshold).should eq ["100.0"]
  end

  it "keeps percent and size levels apart" do
    pct = [Jane::Threshold.new(80.0, :percent), Jane::Threshold.new(90.0, :percent), Jane::Threshold.new(1000.0, :bytes)]
    rows = pct.map { |t| Jane::Monitor.level_check("Memory Usage", t, pct, :alert, "x", t.value.to_s, "m") }
    Jane::Monitor.collapse_levels(rows).map { |r| {r.name, r.threshold} }.should eq [
      {"Memory Usage (%)", "90.0"}, {"Memory Usage (size)", "1000.0"},
    ]
  end
end

require "../src/utils/generate"

describe Jane::Generate do
  it "prints a starter control file that parses without warnings" do
    mounts = [
      Jane::Filesystem::MountEntry.new("/dev/sda2", "/", "ext4", "rw"),
      Jane::Filesystem::MountEntry.new("/dev/sda1", "/boot/efi", "vfat", "rw"),
    ]
    text = Jane::Generate.config_text(mounts)
    config, warnings = build_system(text)
    warnings.should be_empty
    config.check.filesystems.keys.should eq ["root", "boot-efi"]
    config.check.filesystems["boot-efi"].rules.should be_empty # vfat: no inode test
    config.check.cpu.should_not be_nil
    config.check.memory.not_nil!.swap.should_not be_empty
    config.check.processes.keys.should eq ["sshd"]
    config.defaults.cycle.should eq 10
  end
end

describe "Monitor.fit_widths" do
  rows = [
    ["Network Interface em1 (em1)", "alert", "missing", "present", "iperf3 to atlas:5201 failed: unable to connect to server - server may have stopped", "trading, network"],
    ["CPU Usage", "ok", "1.00%", "90.00%", "Within limits", "system"],
  ]

  it "keeps natural widths when the terminal is wide enough or unknown" do
    natural = [27, 6, 7, 9, 82, 16]
    Jane::Monitor.fit_widths(rows, nil).should eq natural
    Jane::Monitor.fit_widths(rows, 200).should eq natural
  end

  it "fits the terminal by shrinking tags, then message and check" do
    [120, 100, 80].each do |cols|
      w = Jane::Monitor.fit_widths(rows, cols)
      (w.sum + w.size * 3 + 1).should eq cols
      w[1].should eq 6 # status never shrinks
    end
    w = Jane::Monitor.fit_widths(rows, 100)
    w[5].should eq 10
    (w[4] - w[0]).abs.should be <= 1 # message and check share the cut
  end

  it "stops at the minimum widths on very small terminals" do
    Jane::Monitor.fit_widths(rows, 40).should eq [14, 6, 7, 9, 16, 6]
  end
end
