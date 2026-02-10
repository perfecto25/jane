
check "filesystem" "root" {
  path = "/"
  usage = "50%"
  alert { when = "usage > 70,75,76" }
  action { exec = "/bin/script/sh" }
}

check "filesystem" "home" {
  path = "/home"
  usage = ["25%", "30%"]
}

filesystem "root-/" {
  path = "/"
  
  alert {
    when = "space usage > 80%"
  }
  
  alert {
    when = "space usage > 85%"
  }
}

# Process checks
process "mysql" {
  pidfile = "/var/run/mysqld/mysqld.pid"
  
  start {
    command = "/usr/sbin/service mysql start"
    timeout = 60
  }
  
  stop {
    command = "/usr/sbin/service mysql stop"
    timeout = 60
  }
  
  alert {
    when   = "totalmem > 400 MB"
    cycles = 5
  }
  
  restart {
    when   = "totalmem > 600 MB"
    cycles = 5
  }
  
  alert {
    when   = "cpu > 50%"
    cycles = 5
  }
  
  restart {
    when   = "cpu > 90%"
    cycles = 5
  }
  
  timeout {
    when = "3 restarts within 5 cycles"
  }
}

process "nginx" {
  pidfile = "/var/run/nginx.pid"
  
  start {
    command = "/usr/sbin/service nginx start"
    timeout = 30
  }
  
  stop {
    command = "/usr/sbin/service nginx stop"
    timeout = 30
  }
  
  alert {
    when   = "cpu > 80%"
    cycles = 5
  }
}

file "app.log" {
  path = "/var/log/app.log"
  
  alert {
    when = "size > 500 MB"
  }
  
  alert {
    when   = "content = ERROR"
    times  = 3
    within = 60
  }
}

host "api-server" {
  address = "api.example.com"
  
  alert {
    when = "failed ping"
  }
}

system "localhost" {
  alert {
    when   = "loadavg (1min) > 4"
    cycles = 5
  }
  
  alert {
    when   = "memory usage > 80%"
    cycles = 5
  }
  
  alert {
    when   = "cpu usage (user) > 90%"
    cycles = 5
  }
}
