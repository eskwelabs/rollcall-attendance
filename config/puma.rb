application_path = '/var/rollcall'
railsenv = 'production'
directory application_path
environment railsenv
daemonize false
pidfile "#{application_path}/tmp/pids/puma-#{railsenv}.pid"
state_path "#{application_path}/tmp/pids/puma-#{railsenv}.state"
threads 0, 16
bind "tcp://0.0.0.0:3000"
