# jane

TODO: Write a description here

## Installation

TODO: Write installation instructions here

## Usage

TODO: Write usage instructions here

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/jane/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [mreider](https://github.com/your-github-user) - creator and maintainer




you are a Crystal language developer

I need you to create a system monitoring application called "Jane" that can do the following

1. is split between an agent and server, the agent runs on a linux system and collects various stats, metrics, etc and sends them to the server using messagepack binary data
2. the server runs as a separate service, it has a web console and shows data coming in from the agents
3. the agent reads in a config TOML file that tells it what to monitor for 

sample config.toml

[log]
destination = "syslog"  #  (options: file/syslog)
file="/var/log/jane.log" # if destination=file
level = "debug"

[check]

[check.cpu]
usage.pct = 15  # alert if CPU usage is above 15%
iowait.pct = 20  # alert if CPU iowait is above 20%
loadavg = [2, 15, 25]  # alert if load average for 1,5,15 minutes is above the values in the array

[check.memory]
usage.gb = 19  # alert if memory usage is above 19 GB

[check.filesystem.home]
path = "/home"
usage.pct = 30 # alert if /home usage is above 30%



4. the agent should also take in CLI arguments 

./jane -i  # show information about the system (make,model, number of CPUs, CPU type, size of memory, hostname, current cpu and memory usage, uptime, load average) in a neat table using Tallboy library or similar libraries that show a nice terminal output
./jane -s # show system status as compared to a config file - should show all checks that are over the limit on top and in red, for example if CPU usage is above 15%, it should put that above anything thats not an alert, also in a nice neat table 
./jane -d # run as daemon, read in config file, compare actual metrics to limits in config file and send all checks as messagepack data to the Server


for now, build just the Agent part of this application in crystal language

I am looking for performance and clean code, the Agent should be very optimized and use as little of system resources as possible to do all this