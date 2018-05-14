# Send-Influx

Simple Powershell Script to send batches of data from Windows counters to an InfluxDB Server.

For collecting regular metrics, you should use [win_perf_counters module](https://github.com/influxdata/telegraf/tree/master/plugins/inputs/win_perf_counters) from [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/) instead.

This script can be useful to send previous batches of data collected with perfmon.exe as .blg files.

# License

This work is licensed under GNU General Public License v3. See [LICENSE] for more details.
