require "spec"
require "file_utils"
require "../src/config"

private def parse(src : String) : Jane::Conf::Parser
  Jane::Conf::Parser.parse_string(src, "test.conf")
end

private def build(src : String) : Tuple(Jane::Config, Array(String))
  parser = parse(src)
  builder = Jane::Conf::Builder.new(parser.document, parser.warnings)
  {builder.build, builder.warnings.map { |pos, msg| "#{pos}: #{msg}" }}
end

private def pcts(list : Array(Jane::Threshold)) : Array(Float64)
  list.map(&.value)
end

describe Jane::Conf::Lexer do
  it "tokenizes words, strings, operators and drops comments" do
    toks = Jane::Conf::Lexer.new(%(check file x with path /var/log/m # comment\n  if content != "a b" then alert ## more)).tokenize
    toks.map(&.text).should eq ["check", "file", "x", "with", "path", "/var/log/m", "if", "content", "!=", "a b", "then", "alert", ""]
    toks[9].kind.string?.should be_true
    toks[7].pos.line.should eq 2
    toks[7].pos.col.should eq 6
  end

  it "keeps service names with dashes and slashes as one word" do
    toks = Jane::Conf::Lexer.new("check filesystem qbtch2-/mnt/hc with path /mnt/hc").tokenize
    toks[2].text.should eq "qbtch2-/mnt/hc"
  end

  it "still accepts set daemon, with a deprecation warning" do
    p = parse("set daemon 30\n")
    p.document.settings.map { |s| {s.key, s.value} }.should eq [{"cycle", "30"}]
    p.warnings.map(&.[1]).should eq ["'set daemon' is deprecated, use 'set cycle 30'"]
  end

  it "keeps regex backslashes in strings; only \\\" and \\\\ are escapes" do
    src = %q(matching ".*myapp\.sh" "-D \[l\]" "say \"hi\"" 'it\'s' "a\\b" "\d+\n")
    toks = Jane::Conf::Lexer.new(src).tokenize
    toks[1, 6].map(&.text).should eq [%q(.*myapp\.sh), %q(-D \[l\]), %q(say "hi"), "it's", %q(a\b), %q(\d+\n)]
  end
end

describe Jane::Conf::Parser do
  it "parses jane's one-rule-per-level filesystem style" do
    doc = parse(<<-CONF).document
      check filesystem root-/ with path /
          if space usage > 80% then alert
          if space usage > 85% then alert
      CONF
    svc = doc.services.first
    svc.type.should eq "filesystem"
    svc.name.should eq "root-/"
    svc.attrs["path"].should eq "/"
    svc.rules.size.should eq 2
    svc.rules[1].test.should eq "space usage"
    svc.rules[1].op.should eq Jane::Conf::Op::GT
    svc.rules[1].values.first.num.should eq 85.0
    svc.rules[1].values.first.unit.should eq "%"
  end

  it "parses threshold lists with a shared unit" do
    ["75, 80, 85 %", "75,80,85%", "75, 80, 85%", "75%, 80%, 85%"].each do |list|
      rule = parse("check filesystem r with path /\n if space usage > #{list} then alert").document.services.first.rules.first
      rule.values.map(&.num).should eq [75.0, 80.0, 85.0]
      rule.values.map(&.unit).should eq ["%", "%", "%"]
    end
  end

  it "parses one-line checks separated by ;" do
    svc = parse(%(check file kernel-error with path /var/log/messages; if content = "kernel: BUG" then alert)).document.services.first
    svc.attrs["path"].should eq "/var/log/messages"
    svc.rules.first.test.should eq "content"
    svc.rules.first.op.should eq Jane::Conf::Op::EQ
    svc.rules.first.values.first.str.should eq "kernel: BUG"
  end

  it "parses loadavg arguments, cycle windows and exec actions" do
    rule = parse(%(check system h\n if loadavg (5min) > 80 for 2 times within 64 cycles then exec "/etc/jane/scripts/top.py cpu")).document.services.first.rules.first
    rule.test.should eq "loadavg"
    rule.arg.should eq "5min"
    rule.times.should eq 2
    rule.cycles.should eq 64
    rule.action.kind.exec?.should be_true
    rule.action.command.should eq "/etc/jane/scripts/top.py cpu"
  end

  it "parses programs with every, == and group" do
    svc = parse(<<-CONF).document.services.first
      check program zombie with path "/etc/jane/scripts/zombie.sh signal_gen"
          every 15 cycles
          if content == "zombie state" then alert ## alert every 5 min
          group trading_hours
      CONF
    svc.type.should eq "program"
    svc.attrs["path"].should eq "/etc/jane/scripts/zombie.sh signal_gen"
    svc.every.should eq "15"
    svc.tags.should eq ["trading_hours"]
    svc.rules.first.values.first.str.should eq "zombie state"
  end

  it "parses process matching and pidfile, and consecutive checks without rules" do
    doc = parse(<<-CONF).document
      check process sfptpd matching "/sbin/sfptpd -f /etc/sfptpd"
      check process sig with pidfile /opt/pidfiles/sig.pid
          group sim
      check network p1p1 with interface p1p1
      CONF
    doc.services.map(&.name).should eq ["sfptpd", "sig", "p1p1"]
    doc.services[0].attrs["matching"].should eq "/sbin/sfptpd -f /etc/sfptpd"
    doc.services[1].attrs["pidfile"].should eq "/opt/pidfiles/sig.pid"
    doc.services[1].tags.should eq ["sim"]
    doc.services[2].attrs["interface"].should eq "p1p1"
  end

  it "parses status != 0, failed port with protocol, and recovery actions" do
    doc = parse(<<-CONF).document
      check program mod with path "/bin/grep -e ^onload /proc/modules"
          if status != 0 then alert
      check host db with address 10.0.0.5
          if failed port 5432 protocol pgsql then alert else if succeeded then alert
      CONF
    doc.services[0].rules.first.op.should eq Jane::Conf::Op::NE
    doc.services[0].rules.first.values.first.num.should eq 0.0
    rule = doc.services[1].rules.first
    rule.test.should eq "failed port"
    rule.test_args.should eq ["5432", "protocol", "pgsql"]
    rule.recovery.should_not be_nil
  end

  it "skips unsupported set statements with a warning" do
    p = parse("set httpd port 2812 and use address localhost allow localhost\nset cycle 5\n")
    p.document.settings.map(&.key).should eq ["cycle"]
    p.warnings.first[1].should contain "set httpd"
  end

  it "follows includes relative to the including file" do
    dir = File.tempname("jane-conf")
    Dir.mkdir_p(File.join(dir, "conf.d"))
    begin
      File.write(File.join(dir, "jane.conf"), "set cycle 5\ninclude conf.d/*.conf\n")
      File.write(File.join(dir, "conf.d", "a.conf"), %(check process a matching "a"\n))
      File.write(File.join(dir, "conf.d", "b.conf"), %(check process b matching "b"\n))
      doc = Jane::Conf::Parser.parse_file(File.join(dir, "jane.conf")).document
      doc.services.map(&.name).should eq ["a", "b"]
      doc.services[1].pos.file.should end_with "conf.d/b.conf"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports errors with file, line, column and a caret" do
    ex = expect_raises(Jane::Conf::ParseError) do
      parse("check filesystem r with path /\n    if space usage > 80% alert")
    end
    ex.message.not_nil!.should start_with "test.conf:2:26: expected 'then', got 'alert'"
    ex.message.not_nil!.should contain "^"
  end

  it "rejects unknown check types, units and impossible cycle windows" do
    expect_raises(Jane::Conf::ParseError, /unknown check type 'filesytem'/) { parse("check filesytem r") }
    expect_raises(Jane::Conf::ParseError, /unknown unit 'xb'/) { parse("check filesystem r with path /\n if space usage > 5xb then alert") }
    expect_raises(Jane::Conf::ParseError, /can never be satisfied/) { parse("check system s\n if cpu > 5% for 9 times within 3 cycles then alert") }
  end
end

describe Jane::Conf::Builder do
  it "merges separate rules and lists into sorted threshold levels" do
    config, _ = build(<<-CONF)
      check filesystem root-/ with path /
          if space usage > 90% then alert
          if space usage > 80, 85 % then alert
          if space usage > 5 GB then alert
      CONF
    fs = config.check.filesystems["root-/"]
    fs.path.should eq "/"
    fs.usage.map { |t| {t.value, t.unit} }.should eq [{80.0, :percent}, {85.0, :percent}, {90.0, :percent}, {5.0 * 1024 ** 3, :bytes}]
  end

  it "maps check system to cpu, iowait, loadavg and memory" do
    config, warnings = build(<<-CONF)
      check system h
          if cpu usage > 90% then alert
          if cpu (wait) > 20% then alert
          if loadavg (5min) > 8, 4 then alert
          if memory > 85% then alert
          if memory > 90% then exec "/usr/bin/top.py mem"
          group sys
      CONF
    cpu = config.check.cpu.not_nil!
    pcts(cpu.usage).should eq [90.0]
    pcts(cpu.iowait).should eq [20.0]
    cpu.loadavg.map { |l| l.map(&.value) }.should eq [[] of Float64, [4.0, 8.0], [] of Float64]
    cpu.tags.should eq ["sys"]
    mem = config.check.memory.not_nil!.usage
    pcts(mem).should eq [85.0, 90.0]
    mem[0].policy.commands.should be_empty
    mem[1].policy.commands.should eq ["/usr/bin/top.py mem"]
    mem[1].policy.action.should eq "exec"
    warnings.should be_empty
  end

  it "maps swap and per-core load average" do
    config, warnings = build(<<-CONF)
      check system h
          if loadavg (1min) per core > 2, 1.5 then alert
          if loadavg per core > 3 then alert
          if loadavg (15min) > 10 then alert
          if swap usage > 25 % then alert
          if swap > 2 GB then exec "/usr/bin/top.py swap"
      CONF
    warnings.should be_empty
    cpu = config.check.cpu.not_nil!
    cpu.loadavg_per_core.map { |l| l.map(&.value) }.should eq [[1.5, 2.0, 3.0], [] of Float64, [] of Float64]
    cpu.loadavg.map { |l| l.map(&.value) }.should eq [[] of Float64, [] of Float64, [10.0]]
    mem = config.check.memory.not_nil!
    mem.usage.should be_empty
    mem.swap.map(&.unit).should eq [:percent, :bytes]
    mem.swap[1].policy.commands.should eq ["/usr/bin/top.py swap"]
  end

  it "maps processes, files, hosts, networks and bandwidth" do
    config, _ = build(<<-CONF)
      check process redir matching "/usr/bin/redir"
      check process sig with pidfile /run/sig.pid
      check file hosts with path /etc/hosts
          if failed uid root then alert
          if failed gid "wheel" then alert
          if failed permission 0644 then alert
      check host db with address 10.0.0.5
          if failed port 5432 then alert
          if failed port 22 then alert
      check network bond0 with interface bond0
      check bandwidth atlas with address atlas port 5202
          if bandwidth < 2 Gbps then alert
      CONF
    c = config.check
    c.processes["redir"].match.should eq "/usr/bin/redir"
    c.processes["sig"].pidfile.should eq "/run/sig.pid"
    f = c.files["hosts"]
    {f.path, f.user, f.group, f.mode}.should eq({"/etc/hosts", "root", "wheel", "644"})
    c.network_connections.keys.should eq ["db:5432", "db:22"]
    c.network_interfaces["bond0"].interface.should eq "bond0"
    bw = c.network_bandwidths["atlas"]
    {bw.port, bw.limit}.should eq({5202, 2000.0})
  end

  it "maps set statements to log, defaults, hq and email alerts" do
    config, _ = build(<<-CONF)
      set cycle 5
      set log /var/log/jane.log level debug
      set hq hq.example.com port 25900
      set mailserver smtp.example.com port 2525
      set alert ops@example.com cc oncall@example.com
      CONF
    config.defaults.cycle.should eq 5
    {config.log.destination, config.log.file, config.log.level}.should eq({"file", "/var/log/jane.log", "debug"})
    hq = config.hq.not_nil!
    {hq.host, hq.port, hq.enabled}.should eq({"hq.example.com", 25900, true})
    email = config.alert.not_nil!.email.not_nil!
    {email.smtp_server, email.smtp_port, email.send_to, email.send_cc}.should eq({"smtp.example.com", 2525, "ops@example.com", "oncall@example.com"})
  end

  it "warns about what the engine can't do yet instead of dropping it silently" do
    _, warnings = build(<<-CONF)
      check filesystem r with path /
          if read rate > 10 MB/s then alert
          if space usage > 90% then unmonitor
      check host h with address 10.0.0.1
          if failed ping then alert
      check process p matching "p"
          depends on r
      CONF
    warnings.should eq [
      "test.conf:2:5: test 'read rate' is not supported yet for 'check filesystem'; rule skipped",
      "test.conf:3:5: 'then unmonitor' is not supported yet; the rule will only alert",
      "test.conf:5:5: test 'failed ping' is not supported yet for 'check host'; rule skipped",
      "test.conf:4:1: 'check host h' has no 'if failed port' rule; nothing will be checked",
      "test.conf:6:1: 'depends on' is not supported yet and was ignored",
    ]
  end

  it "builds policies from cycle windows, exec, repeat, restart and recovery" do
    config, warnings = build(<<-CONF)
      check process nginx with pidfile /run/nginx.pid
          start program = "/bin/systemctl start nginx"
          stop program = "/bin/systemctl stop nginx"
          if does not exist for 3 cycles then restart else if succeeded then exec "/bin/notify ok"
      check file log with path /var/log/messages
          if content = "Out of memory" for 2 times within 30 cycles then exec "/bin/dump" repeat every 5 cycles
      CONF
    warnings.should be_empty
    p = config.check.processes["nginx"].policy
    {p.times, p.cycles, p.action}.should eq({3, 3, "restart"})
    p.commands.should eq ["/bin/systemctl stop nginx", "/bin/systemctl start nginx"]
    p.recovery_commands.should eq ["/bin/notify ok"]
    rule = config.check.files["log"].content_rules.first
    rule.op.eq?.should be_true
    rule.pattern.source.should eq "Out of memory"
    {rule.policy.times, rule.policy.cycles, rule.policy.repeat}.should eq({2, 30, 5})
    rule.policy.commands.should eq ["/bin/dump"]
  end

  it "builds process resource rules" do
    config, warnings = build(<<-CONF)
      check process app matching "/usr/bin/app"
          if cpu > 80% for 5 cycles then alert
          if total cpu usage > 150% then alert
          if memory > 500 MB then alert
          if total memory > 10% then alert
          if threads > 200 then alert
          if children > 20 then alert
          if uptime < 3 minutes then alert
          if changed pid then alert
          if changed ppid then alert
          if failed port 8080 type tcp then alert
          if failed host 10.0.0.1 port 22 expect "^SSH-" then alert
      CONF
    warnings.should be_empty
    rules = config.check.processes["app"].rules
    rules.map(&.label).should eq [
      "cpu > 80%", "total cpu > 150%", "memory > 500.00 MB", "total memory > 10%", "threads > 200",
      "children > 20", "uptime < 3m", "pid changed", "ppid changed", "port 8080", "port 22",
    ]
    rules[0].policy.times.should eq 5
    rules[2].value.should eq 500.0 * 1024 ** 2
    rules[6].value.should eq 180.0
    {rules[10].probe.not_nil!.address, rules[10].probe.not_nil!.expect.try(&.source)}.should eq({"10.0.0.1", "^SSH-"})
    rules[9].probe.not_nil!.address.should eq "localhost"
  end

  it "builds process disk I/O rules with rates per period" do
    config, warnings = build(<<-CONF)
      check process db matching "postgres"
          if disk read > 10 MB/s for 3 cycles then alert
          if disk write rate > 600 MB/min then alert
          if total disk write > 500 operations/s then alert
          if total disk read > 7200 ops/h then alert
          if disk write > 5MB/s then alert
      CONF
    warnings.should be_empty
    rules = config.check.processes["db"].rules
    rules.map(&.label).should eq [
      "disk read > 10.00 MB/s", "disk write > 10.00 MB/s", "total disk write > 500 ops/s",
      "total disk read > 2 ops/s", "disk write > 5.00 MB/s",
    ]
    rules.map(&.unit).should eq [:bytes_rate, :bytes_rate, :ops_rate, :ops_rate, :bytes_rate]
    rules[0].value.should eq 10.0 * 1024 ** 2
    rules[0].policy.times.should eq 3
  end

  it "rejects disk I/O values that aren't rates" do
    expect_raises(Jane::Conf::ParseError, /needs a rate/) { build(%(check process a matching "a"\n if disk read > 10 MB then alert)) }
    expect_raises(Jane::Conf::ParseError, /unknown unit 'MB\/fortnight'/) { build(%(check process a matching "a"\n if disk read > 10 MB/fortnight then alert)) }
  end

  it "rejects malformed process rules" do
    expect_raises(Jane::Conf::ParseError, /can only be tested for change/) { build(%(check process a matching "a"\n if pid > 3 then alert)) }
    expect_raises(Jane::Conf::ParseError, /needs a percentage, e.g./) { build(%(check process a matching "a"\n if cpu > 3 GB then alert)) }
    expect_raises(Jane::Conf::ParseError, /needs a duration/) { build(%(check process a matching "a"\n if uptime > 3 GB then alert)) }
    expect_raises(Jane::Conf::ParseError, /only TCP ports/) { build(%(check process a matching "a"\n if failed port 53 type udp then alert)) }
  end

  it "keeps expect patterns on host port checks" do
    config, _ = build(%(check host ssh with address 10.0.0.2\n if failed port 22 expect "^SSH-" then alert))
    config.check.network_connections["ssh"].expect.try(&.source).should eq "^SSH-"
  end

  it "builds file timestamp, size and checksum rules" do
    md5 = "d41d8cd98f00b204e9800998ecf8427e"
    sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    config, warnings = build(<<-CONF)
      check file hb with path /var/run/hb
          if timestamp > 5 minutes for 2 cycles then alert
          if modify timestamp < 10 s then alert
          if changed access timestamp then alert
          if size > 2 GB then alert
          if size = 0 then alert
          if changed size then alert
          if failed checksum expect "#{md5}" then alert
          if failed sha256 checksum and expect the sum #{sha256} then alert
          if failed sha1 checksum then alert
          if changed checksum then alert
          if changed sha256 checksum then exec "/bin/notify"
      CONF
    warnings.should be_empty
    file = config.check.files["hb"]
    file.kind.should eq :file
    file.rules.map(&.label).should eq [
      "timestamp > 5m", "modify timestamp < 10s", "access timestamp changed", "size > 2.00 GB", "size = 0 B",
      "size changed", "md5 checksum", "sha256 checksum", "sha1 checksum", "md5 checksum changed", "sha256 checksum changed",
    ]
    file.rules[0].policy.times.should eq 2
    file.rules[0].value.should eq 300.0
    file.rules[3].value.should eq 2.0 * 1024 ** 3
    file.rules[6].expect.should eq md5
    file.rules[7].expect.should eq sha256
    file.rules[8].expect.should be_nil
    file.rules[10].policy.commands.should eq ["/bin/notify"]
  end

  it "builds directory and fifo checks" do
    config, warnings = build(<<-CONF)
      check directory spool with path /var/spool/app
          if changed timestamp then alert
          if failed uid app then alert
      check fifo ctl with path /run/app.fifo
          if timestamp > 1 hour then alert
      CONF
    warnings.should be_empty
    dir = config.check.files["spool"]
    {dir.kind, dir.prefix, dir.user, dir.rules.map(&.label)}.should eq({:directory, "Directory", "app", ["timestamp changed"]})
    fifo = config.check.files["ctl"]
    {fifo.kind, fifo.prefix}.should eq({:fifo, "Fifo"})
  end

  it "rejects malformed file rules" do
    expect_raises(Jane::Conf::ParseError, /only works on 'check file', not 'check directory'/) do
      build("check directory d with path /x\n if size > 1 GB then alert")
    end
    expect_raises(Jane::Conf::ParseError, /has 31 digits/) do
      build("check file f with path /x\n if failed checksum expect \"d41d8cd98f00b204e9800998ecf8427\" then alert")
    end
    expect_raises(Jane::Conf::ParseError, /a sha1 checksum has 40 digits, got 32/) do
      build("check file f with path /x\n if failed sha1 checksum expect \"d41d8cd98f00b204e9800998ecf8427e\" then alert")
    end
    expect_raises(Jane::Conf::ParseError, /use 'if changed checksum'/) do
      build("check file f with path /x\n if checksum > 3 then alert")
    end
    expect_raises(Jane::Conf::ParseError, /needs a size/) do
      build("check file f with path /x\n if size > 3% then alert")
    end
  end

  it "builds HTTP and TLS port probes" do
    config, warnings = build(<<-CONF)
      check host web with address www.example.com
          if failed port 443 protocol https request "/health?full=1" with hostheader "api.example.com"
             and status = 200 and content = "ok|healthy" and certificate valid > 30 days
             with timeout 5 seconds and ssl options {verify: enable} for 2 cycles then alert
          if failed port 80 protocol http then alert
          if failed port 80 protocol http request "/x" status < 500 content != "error" then alert
          if failed port 25 expect "^220" then alert
      CONF
    warnings.should be_empty
    conns = config.check.network_connections
    conns.keys.should eq ["web:443", "web:80", "web:80 (2)", "web:25"]
    p = conns["web:443"].probe.not_nil!
    {p.address, p.port, p.ssl, p.http, p.request, p.host_header}.should eq({"www.example.com", 443, true, true, "/health?full=1", "api.example.com"})
    {p.status_op, p.status, p.content_op, p.content.try(&.source)}.should eq({Jane::Conf::Op::EQ, 200, Jane::Conf::Op::EQ, "ok|healthy"})
    {p.cert_op, p.cert_days, p.timeout, p.verify}.should eq({Jane::Conf::Op::GT, 30.0, 5, true})
    conns["web:443"].policy.times.should eq 2
    plain = conns["web:80"].probe.not_nil!
    {plain.http, plain.ssl, plain.status_op, plain.verify}.should eq({true, false, nil, false})
    conns["web:80 (2)"].probe.not_nil!.content_op.should eq Jane::Conf::Op::NE
    conns["web:25"].probe.not_nil!.expect.try(&.source).should eq "^220"
  end

  it "builds HTTP probes on process ports" do
    config, _ = build(%(check process app matching "app"\n if failed host 127.0.0.1 port 8080 protocol http request "/ping" then restart\n start program = "/bin/true"\n stop program = "/bin/true"))
    rule = config.check.processes["app"].rules.first
    probe = rule.probe.not_nil!
    {rule.label, probe.address, probe.port, probe.http, probe.request}.should eq({"port 8080", "127.0.0.1", 8080, true, "/ping"})
  end

  it "rejects inconsistent port options" do
    bad = {
      %(if failed port 80 status = 200 then alert)                          => /need 'protocol http' or 'protocol https'/,
      %(if failed port 80 protocol http request "health" then alert)        => /needs a path starting with '\/'/,
      %(if failed port 443 certificate valid > 30 days then alert)          => /'certificate valid' needs TLS/,
      %(if failed port 80 protocol http expect "x" then alert)              => /can't be combined with 'protocol http'/,
      %(if failed port 80 protocol http frobnicate 3 then alert)            => /unknown port option 'frobnicate'/,
      %(if failed port 80 protocol http status = then alert)                => /expected a number after 'status'/,
      %(if failed port 443 protocol https certificate expires > 3 then alert) => /expected 'certificate valid/,
    }
    bad.each do |rule, message|
      expect_raises(Jane::Conf::ParseError, message) { build("check host h with address x\n #{rule}") }
    end
  end

  it "builds filesystem space, inode and fsflags rules" do
    config, warnings = build(<<-CONF)
      check filesystem data with path /data
          if space usage > 80, 90% then alert
          if space free < 10 GB then alert
          if space free < 5% for 2 cycles then alert
          if inode usage > 90% then alert
          if inodes > 1000000 then alert
          if inode free < 5000 then alert
          if changed fsflags then exec "/usr/local/bin/remount-alert"
      CONF
    warnings.should be_empty
    fs = config.check.filesystems["data"]
    pcts(fs.usage).should eq [80.0, 90.0]
    fs.rules.map(&.label).should eq [
      "space free < 10.00 GB", "space free < 5%", "inode usage > 90%", "inode usage > 1000000",
      "inode free < 5000", "fsflags changed",
    ]
    fs.rules.map(&.unit).should eq [:bytes, :percent, :percent, :count, :count, :count]
    fs.rules[1].policy.times.should eq 2
    fs.rules[5].policy.commands.should eq ["/usr/local/bin/remount-alert"]
  end

  it "rejects malformed filesystem rules" do
    expect_raises(Jane::Conf::ParseError, /only be tested for change/) { build("check filesystem d with path /\n if fsflags = rw then alert") }
    expect_raises(Jane::Conf::ParseError, /needs a percentage or a count/) { build("check filesystem d with path /\n if inode free < 5 GB then alert") }
    expect_raises(Jane::Conf::ParseError, /needs a size/) { build("check filesystem d with path /\n if space free < 5 days then alert") }
  end

  it "warns about filesystem checks without rules" do
    _, warnings = build("check filesystem d with path /data")
    warnings.should eq ["test.conf:1:1: 'check filesystem d' has no rules; only checks that '/data' is mounted"]
  end

  it "builds program checks with every, status and content rules" do
    config, _ = build(<<-CONF)
      check program risk with path "/etc/jane/scripts/risk_tcp_check.py sim" with timeout 20 seconds
          every 36 cycles
          if status != 0 then alert
          if content != "ok" then alert
          group risk
      CONF
    prog = config.check.programs["risk"]
    {prog.command, prog.timeout, prog.every, prog.tags}.should eq({"/etc/jane/scripts/risk_tcp_check.py sim", 20, 36, ["risk"]})
    prog.rules.map(&.label).should eq ["status != 0", %(content != "ok")]
  end

  it "rejects restart without start/stop programs and bad patterns" do
    expect_raises(Jane::Conf::ParseError, /needs 'stop program = /) do
      build(%(check process a matching "a"\n if not exist then restart))
    end
    expect_raises(Jane::Conf::ParseError, /invalid pattern/) do
      build("check file f with path /x\n if content = \"(unclosed\" then alert")
    end
    expect_raises(Jane::Conf::ParseError, /needs '=' or '!='/) do
      build(%(check file f with path /x\n if content > "x" then alert))
    end
  end

  it "rejects duplicate service names and incomplete checks" do
    expect_raises(Jane::Conf::ParseError, /duplicate service name 'a'/) do
      build(%(check process a matching "a"\ncheck process a matching "b"))
    end
    expect_raises(Jane::Conf::ParseError, /needs 'matching/) { build("check process x") }
    expect_raises(Jane::Conf::ParseError, /needs 'with path/) { build("check filesystem x") }
  end
end
