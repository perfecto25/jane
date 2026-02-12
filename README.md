# Jane Agent

Fresh, organic, farm to table metrics and events.

## Description

<img src="logo.png" alt="jane" width="150">


Jane is a lightweight sytem and process monitoring software. It is inspired by Tildeslash Monit and uses the same philosophy to report on a system's metrics and observability.

Jane consists of 2 parts

1. Jane agent - a basic monitoring agent that runs on a managed host and reports Metrics and Checks

Metrics show things like CPU utilization, memory usage, process uptime, etc

Checks show whether configured thresholds are over the limit and issue alerts

2. Jane HQ - a central server that receives agent events and uses logical rules to send alerts to users based on Check thresholds. 

---

## Installation

TODO: Write installation instructions here

## Usage

TODO: Write usage instructions here

## Roadmap

- add additional utils (network, process)
- ability to send alerts from agent via smtp host


TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/jane/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [perfecto25](https://github.com/perfecto25) - creator and maintainer
