module Jane
  module Generate
    extend self


    def make_config
      data = <<-TXT
      [log]
      destination = "syslog"
      level = "info"

      [hq]
      enabled = false
      host = "<ip of HQ server>"
      port = 36777

      [defaults]
      cycle = 10
      include.checks = "/etc/jane/conf.d/*.toml"

      [check]
      [check.cpu]
      usage.pct = [80,85,90]
      iowait.pct = 60
      loadavg = [1.5, 2.5, 30.0]
      tag = "cpu"

      [check.memory]
      usage.pct = [80,85,90,95]
      tag = "memory"

      [check.filesystem.home]
      path = "/home"
      usage.pct = [85,90,95]
      tag = "filesystems"

      [check.filesystem.root]
      path = "/"
      usage.pct = [85,90,95]
      tag = "filesystems"

      [check.filesystem.boot]
      path = "/boot"
      usage.pct = [85,90,95]
      tag = "filesystems"

      [check.filesystem.boot-efi]
      path = "/boot/efi"
      usage.pct = [85,90,95]
      tag = "filesystems"

      [check.process.sshd]
      match = "*/usr/sbin/sshd*"
      TXT

      data = data + <<-TXT
      \n# end of file
      TXT
      puts data
    end
  end
end
