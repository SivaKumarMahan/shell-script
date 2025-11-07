# System-Resource-Monitoring-Script

This project is a shell script that monitors system resources such as CPU usage, memory usage, and disk space. It provides real-time information about the system's performance and can be scheduled to run at regular intervals using cron jobs.

## Features
- Logs CPU usage in real time
- Displays memory and disk utilization
- Lists top 5 memory-consuming processes
- Captures system uptime
- Outputs all data to /var/log/system_monitor.log
- Can be automated with cron jobs for daily reporting

## Requirements
- Unix-like operating system (Linux, macOS)
- Bash shell 
- Basic command-line tools (top, free, df)

## Commands Used
- `top` - to monitor CPU and memory usage
- `free` - to check memory usage
- `df` - to check disk space usage
- `uptime` - to get system uptime

## Commands to Run the Script

chmod +x system_monitor.sh 

Run the Script
sudo ./system_monitor.sh

View the Logs
cat /var/log/system_monitor.log 

Automate via Cron To schedule automatic daily system checks at 8 AM:
sudo crontab -e 0 8 * * * /path/to/system_monitor.sh
Replace `/path/to/system_monitor.sh` with the actual path to the script.

# Output Log File: /var/log/system_monitor.log
cat /var/log/system_monitor.log 
----------------------------------------
System Resource Report - 2025-11-07 12:59:36
----------------------------------------
CPU Usage:
CPU Load: 4.7%

Memory Usage:
Used: 12Gi / Total: 15Gi (80.00%)

Disk Usage:
Used: 72G / 257G (30% used)

Top 5 Memory Consuming Processes:
    PID COMMAND         %MEM %CPU
   7141 dotnet           9.9  0.1
   1352 java             5.0  0.1
 641184 code             4.2  1.0
   9307 chrome           3.8  0.6
   4700 code             3.7  0.7

System Uptime:
up 2 days, 14 hours, 26 minutes
----------------------------------------
