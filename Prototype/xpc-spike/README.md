# XPC routing and authentication spike (Stage 1, issue #67)

Can AegisCore (a background agent) reach ModelService over XPC **with the Aegis app closed**, with ModelService started only when needed and refusing callers that aren't Aegis? Results: `docs/stages/STAGE-1-SPIKES.md`, section 1.5.

The test app registers two launch agents with `SMAppService` and quits:
- **model-agent** (ModelService stand-in) publishes the Mach service `dev.aegis.xpcsigned.model`. launchd starts it only when a client looks the service up; it exits by itself after 5 s with no job.
- **core-agent** (AegisCore stand-in) runs once at registration: cold start, warm job, a job after ModelService's idle exit, a job interrupted by killing ModelService, a retry, and a new connection. It writes timings to `/private/tmp/aegis-xpc-spike/core-result.json` and exits.
- **rogue-wrong-id** and **rogue-spoofed-id** are clients ModelService should refuse: one signed with another identifier, one ad hoc signed with Core's identifier.

Nothing reads personal data; jobs are timers. Logs hold fixed event names, process IDs and timings.

It needs the Apple Development certificate. The first runs (1.5) were ad hoc under the labels `dev.aegis.xpcspike.*`; macOS remembers an agent's first signature, so the spike now uses `dev.aegis.xpcsigned.*` and always signs with the team (1.5b).

## Run

```bash
Prototype/xpc-spike/build.sh
open -W -n "Prototype/output/xpc-spike/Aegis XPC Spike.app" --args register
sleep 30; cat /private/tmp/aegis-xpc-spike/spike.log
Prototype/output/xpc-spike/rogue-wrong-id
Prototype/output/xpc-spike/rogue-spoofed-id
open -W -n "Prototype/output/xpc-spike/Aegis XPC Spike.app" --args unregister
```

Always unregister afterwards: Core's plist has `RunAtLoad`, so it would run again at the next login.

`Resources/dev.aegis.xpcsigned.model.plist` sets `ThrottleInterval` to 1 s (variant B). Remove those lines to see launchd's default 10 s throttle (variant A).
