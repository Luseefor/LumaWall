# 0005: The media service exits when an accepted request overruns

## Context

An import stalled after the sandboxed media service stopped answering.
Later requests opened new connections to the same process and stalled
too. The service's watchdog depended on Swift's cooperative pool, where
media work also runs. See #125.

## Decision

- The service records a 110-second deadline for each request it accepts
  before scheduling its work. Requests over the concurrency cap get an
  immediate error. Work remains tracked until it returns, even after its
  connection drops and cancellation is requested.
- A Dispatch timer checks those deadlines once a second on a dedicated
  serial queue. If any accepted request is overdue, the service calls
  `exit(EXIT_FAILURE)`. Launchd can start a fresh process for a later
  request, subject to its restart throttle.
- The client gives up after a 120-second wall-clock deadline and
  invalidates only the request's connection. A reply or proxy error
  claims the continuation and cancels the timer as soon as it arrives.
  Process lookup and signals would risk acting on a reused PID or
  terminating a healthy replacement.

## Consequences

A service exit fails other requests sharing the process. A request that
never reaches the service can only be timed out by the client. The service
watchdog covers work waiting to run as well as work in progress.

## Tests

The deadline unit test advances a supplied time to check pending and
finished requests. An in-process XPC listener that never replies
exercises the client timeout. The inspect and poster test exercises the
embedded sandboxed service.
