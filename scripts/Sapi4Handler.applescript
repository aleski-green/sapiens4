-- Launch Services delivers custom URLs as open-location events, not argv.
on open location incomingURL
	if incomingURL is in {"sapi4://corpora", "sapi4://corpora/", "sapi4:corpora"} then
		my openWorkspace()
	else
		display alert "Unknown Sapi4 link" message "Use sapi4://corpora to open your workspace."
	end if
end open location

on run
	my openWorkspace()
end run

on openWorkspace()
	set registryPath to (POSIX path of (path to home folder)) & "Library/Application Support/Sapiens4/workspace.plist"
	try
		set serverPort to (do shell script "/usr/libexec/PlistBuddy -c 'Print :port' " & quoted form of registryPath) as integer
		set serverPID to (do shell script "/usr/libexec/PlistBuddy -c 'Print :pid' " & quoted form of registryPath) as integer
		if serverPort < 1 or serverPort > 65535 or serverPID < 1 then error "Invalid server registration"
		do shell script "/bin/kill -0 " & serverPID
		-- Only a numeric port is used; URLs cannot choose a host or shell command.
		set baseURL to "http://127.0.0.1:" & serverPort
		set health to do shell script "/usr/bin/curl --noproxy '*' --fail --silent --max-time 3 " & quoted form of (baseURL & "/api/health")
		if health does not contain "\"status\": \"ok\"" or health does not contain "\"provider\": \"codex\"" then error "Server unavailable"
	on error
		display alert "Sapiens4 is not running" message "Start Sapiens4 from your project, then open sapi4://corpora again. The server registers its current port automatically."
		return
	end try
	do shell script "/usr/bin/open " & quoted form of (baseURL & "/workspace/")
end openWorkspace
