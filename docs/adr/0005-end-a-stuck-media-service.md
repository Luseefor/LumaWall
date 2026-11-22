# 0005: A media request that times out ends the service process

## Context

Issue #125: importing could stall for minutes. The sandboxed
`LumaWallMediaService` had stopped answering: one idle thread, no CPU,
no sandbox denials. The app's client gives up after 120 seconds, but
each request opens a new connection to the same process, so every later
inspect and poster request in the import queued behind the stuck one and
waited out its own 120 seconds.

The service's own 110-second deadline (`MediaServiceWork`) ends the
process only when a request it started is still running. A process that
never starts a request is never ended by it.

## Decision

- When a request times out, `MediaServiceClient` sends `SIGKILL` to the
  process on the other end of that connection (`processIdentifier`,
  read before the connection is invalidated). launchd starts a fresh
  process for the next request, after its relaunch throttle of about
  10 seconds.
- The timeout is a dispatch timer, not a `Task.sleep`, so it fires even
  when Swift's cooperative pool is busy.
- The client never signals its own pid. A connection to an in-process
  listener, as in the tests, reports it.

## Consequences

- One stuck file costs one timeout plus about 10 seconds, not a timeout
  for every request after it.
- A request that is slow but healthy, past 120 seconds, is killed too.
  Inspection and stills take well under a second on the clips we've
  tried, so 120 seconds leaves a wide margin.
- Another app request using the same process when it's killed fails with
  `serviceUnavailable` through its connection's error handler, as with
  any service crash.
- The app has to stay unsandboxed or keep the right to signal its own
  XPC service.
- Why the service stopped answering is not explained yet. It didn't
  reproduce on this Mac in about 400 requests, including 30 fresh service
  processes. See #125.
