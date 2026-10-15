# Festival Programme Sync — Take-Home

**Role:** Senior Rails / Hotwire Developer · **Time box:** 4 hours
**Stack:** Rails 8, Hotwire, PostgreSQL, Sidekiq, Tailwind (all in Docker)

## Context

You're joining a team that maintains a film festival's public website. It's a
Rails monolith that also acts as the editorial CMS, and it pulls programming data
from an external festival-management system over an API.

That external system is the source of truth for films, venues and screenings. Our
database holds a local copy so the site renders fast and stays up under load.
Today that copy is refreshed by a nightly script a colleague wrote in a hurry, and
it's been causing problems.

**Your job is to replace it.**

## What we've given you

A working Rails 8 app with `Film`, `Venue` and `Screening` models, a mock external
API at `/mock_api` that behaves like the real one including its failure modes, an
existing `VenueSync` service and its tests, a screenings index with a filter form,
and seed data.

### Running it

Everything runs in Docker. One step:

```bash
docker compose up --build
```

That starts Postgres, Redis, the Rails web server, a Tailwind watcher and Sidekiq,
and creates/migrates/seeds the database on first boot.

- App: <http://localhost:3000>
- Sidekiq dashboard: <http://localhost:3000/sidekiq>
- Postgres is exposed on host port **5544** (non-standard, so it won't collide)

Handy commands (see the `Makefile`):

```bash
make console   # rails console inside the web container
make test      # run the RSpec suite
make sh        # a shell in the web container
```

## What we'd like you to build

1. **A programme sync.** Pull screenings from `GET /mock_api/screenings` into our
   database. It's paginated, returns nested film and venue data, and behaves like a
   real third-party API: sometimes slow, sometimes failing partway through, and its
   records change between runs.

   Running it twice must not create duplicates. Running it after upstream data
   changes must update the local copy. If the API fails partway, records already
   retrieved shouldn't be lost. It should run on a schedule as a background job, and
   we should be able to tell afterwards whether a run succeeded and what it did.

2. **A filtered screenings list.** The index at `/screenings` has a filter form that
   reloads the whole page. Make it update just the results. Filters are date, venue,
   and a text search across titles. Keep it server-rendered; we're a Hotwire shop and
   aren't looking for a client-side rendering layer.

3. **A short README.** Half a page. What you'd do differently with more time, anything
   in the existing code you'd change and why, and any assumptions you made.

## Testing the mock API

| Parameter      | Effect                                                                                                     |
| -------------- | ---------------------------------------------------------------------------------------------------------- |
| `?page=2`      | Pagination, 25 records per page                                                                            |
| `?generation=2`| The dataset after upstream changes. Screenings have moved venue, some are cancelled, a film has been retitled, two screenings are new. |
| `?fail_after=8`| Returns 8 records, then a 500                                                                              |
| `?slow=true`   | Six-second delay                                                                                           |

Sync `generation=1`, then `generation=2`, and check the database is right. Then try
`generation=1&fail_after=8` and check nothing was lost.

## What we care about

- **Correctness under failure, ahead of feature completeness.** If you run short, a
  sync that handles the edge cases and a filter that doesn't quite work beats the
  reverse.
- Tests are expected — at least for the sync and the models. Tests for the view
  layer aren't. We're looking at how you test, not just that you did, so write
  your own; the repo doesn't hand you a test plan.

## Background synchronization

Enqueue a sync using the existing Redis and Sidekiq services:

```bash
docker compose exec -T web bin/rails runner 'ProgrammeSyncJob.perform_later(generation: 1)'
```

Use `generation: 2` to import the changed mock dataset. Each execution attempt
creates its own SyncRun, including failed attempts. Connection failures, timeouts,
HTTP 408/429 and 5xx responses get at most three attempts total, 30 seconds apart.
Malformed data, invalid JSON and other HTTP errors are not retried automatically.
Active Job manages retries; Sidekiq's additional retry cycle is disabled for this job.

For a nightly sync at 02:00 in the host's timezone, install this entry in the
Docker user's crontab, replacing the project and Docker executable paths:

```cron
0 2 * * * cd /absolute/path/to/festival-programme-sync && /usr/bin/docker compose exec -T web bin/rails runner 'ProgrammeSyncJob.perform_later(generation: 1)' >> /tmp/festival-programme-sync-cron.log 2>&1
```

The host must be running, the cron user must have Docker access, and the web,
Redis and Sidekiq services must be up. Cron only enqueues; Sidekiq performs the
import on the default queue. Inspect SyncRun records for outcomes and worker logs
for errors. No scheduler gem or cron installation inside containers is needed.

## Submitting

A private git repo with your commits. Please don't squash.
