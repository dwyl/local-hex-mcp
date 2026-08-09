# Ingestion coordination, step by step

How two callers asking for the same uningested package end up doing the work
once. Written as a sequence, with the ordering constraints called out — most of
the design is *ordering*, and each ordering exists because reversing it opens a
specific race.

The moving parts:

- `StdioMcp.IngestionRegistry` — **unique** registry. Holds at most one entry per
  `{owner, package, version}`. Owning that entry *is* the right to do the work.
- `StdioMcp.IngestionWaiters` — **duplicate** registry. Every caller waiting for
  that key, however many there are.
- `StdioMcp.TaskSupervisor` — where the job actually runs, unlinked from whoever
  asked for it.
- `Docs.IngestionJob.run/5` — what a caller calls. Everything below is inside it.

## The sequence, with two callers

**1. Caller A: is it already indexed?**

`Docs.Search` resolves the version first, then checks whether rows exist for
that `{package, version}`. If they do, ingestion never enters the picture and the
query runs immediately. Only a miss reaches `IngestionJob.run/5`.

**2. Caller A: subscribe *before* doing anything else.**

```elixir
{:ok, _} = Registry.register(@waiters, key, nil)
```

This is first, and it has to be. If a caller started the job and *then*
subscribed, a fast job could finish and `Registry.dispatch` to an empty waiter
list — the result goes to nobody, and the caller that asked for it blocks until
its timeout waiting for a message that was already sent. Subscribing first makes
that impossible: the job cannot complete before the caller is on the list.

**3. Caller A: look for a running job.**

`ensure_started/2` looks the key up in the jobs registry. Nothing there, so it
starts a task under the supervisor.

The lookup is an *optimisation*, not the guarantee. Two callers can both look at
the same instant, both see nothing, and both start a task. That is expected and
handled — see step 5.

**4. The task claims the key.**

Inside the task, before any work:

```elixir
case Registry.register(@jobs, key, meta) do
  {:ok, _}                            -> # won: do the work, then broadcast
  {:error, {:already_registered, _}}  -> # lost: return immediately, do nothing
end
```

**This is the actual single-flight guarantee.** The unique registry makes the
claim atomic, so exactly one task can hold the key no matter how many were
spawned. A losing task does no download, no embedding, and exits.

Note what this buys: correctness does not depend on the step-3 lookup being
accurate. The lookup only avoids spawning a task that would immediately give up.

**5. Caller B arrives.**

Same path: not in SQLite, subscribes to waiters, looks up the key. Two outcomes,
both fine:

- **Sees A's task** — attaches to that pid, spawns nothing.
- **Sees nothing** (it looked a moment too early) — spawns a second task, which
  loses the `Registry.register` race in step 4 and exits at once.

In the second case caller B is now monitoring a process that is about to die
without producing anything. That is what the `:DOWN` clause in `do_wait/4` is
for:

```elixir
{:DOWN, ^ref, :process, ^pid, reason} ->
  case Registry.lookup(@jobs, key) do
    [{owner, _meta}] when owner != pid ->
      do_wait(key, owner, Process.monitor(owner), deadline)   # re-attach
    _ ->
      drain(key, reason)
  end
```

The caller notices its task died, asks who actually owns the key, and starts
waiting on the winner instead — with the *original* deadline, so losing the race
costs no extra time.

**6. Both callers wait.**

Each sits in `do_wait/4` with a monitor on the job and a deadline. Three ways out:

- `{:ingestion_done, key, result}` — the result, not a signal to go re-read the
  database. The job broadcasts whatever `work.()` returned.
- `{:DOWN, ...}` — handled as in step 5.
- timeout — returns `{:timeout, progress(key)}`, where progress is read live from
  the job's registry value (stage and elapsed ms), which is how the payload can
  say "embedding 7/18, 20s elapsed".

**7. The job finishes and broadcasts.**

`Registry.dispatch(@waiters, key, ...)` sends to every subscribed pid. Both
callers wake with the same result. No caller re-runs the work, and no caller
re-queries to discover whether it succeeded.

A crash inside `work` is caught and broadcast as `{:error, {kind, reason}}`
rather than allowed to kill the task silently — otherwise every waiter would sit
out its full timeout for a result that is never coming.

**8. Everyone unsubscribes.**

`run/5` wraps the whole wait in `try/after` with
`Registry.unregister(@waiters, key)`, so a caller that times out, crashes or
returns normally always leaves the waiter list clean.

## Two consequences worth knowing

**A timeout does not cancel anything.** The job runs under the supervisor,
unlinked from the caller, so a caller giving up leaves it running. The next
request either finds finished rows in SQLite or attaches to the same job and
reports its progress. This is why an impatient retry is cheap — and why
`refresh: true` on a retry is wrong: it starts a *different* key's work rather
than joining the one already running.

**Mailbox ordering closes the last gap.** The job dispatches its result and only
then exits. Messages from one process arrive in order, so when a waiter sees the
`:DOWN` first, the result is already sitting behind it in the mailbox. `drain/1`
does one non-blocking `receive` to pick it up before concluding the job died:

```elixir
receive do
  {:ingestion_done, ^key, result} -> result
after
  0 -> {:error, {:job_exited, reason}}
end
```

Without that, a job that succeeded and exited immediately would be reported as a
failure.

## Why the races are cheap here

Four separate races appear above: subscribe-vs-dispatch, lookup-vs-spawn,
claim-vs-claim, and result-vs-exit. Each is closed by something the runtime
provides rather than something this code implements — an atomic registry insert,
process monitors, per-sender message ordering, and `try/after` running on any
exit path. That is most of what a supervised BEAM process buys, and it is why
the file is 169 lines and has no locks in it.
