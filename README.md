# Festival Programme Sync

Senior Rails / Hotwire Developer — Technical Assessment

**Stack:** Rails 8 · Hotwire · PostgreSQL · Sidekiq · Redis · Tailwind CSS · Docker

## Overview

A Rails application that maintains a local copy of a film festival's programme, synchronized from an external festival-management API.

The implementation focuses on reliable synchronization, graceful handling of partial failures, background processing, and a responsive server-rendered screenings interface.

## Getting Started

Start the application and its dependencies:

```bash
docker compose up --build
```

This starts Rails, PostgreSQL, Redis, Sidekiq, and Tailwind. The database is prepared and seeded on first boot.

- **Application:** http://localhost:3000/screenings
- **Sidekiq dashboard:** http://localhost:3000/sidekiq
- **PostgreSQL:** localhost:5544

Useful commands:

```bash
make test       # Run the RSpec suite
make console    # Open Rails console
make sh         # Open a shell inside the web container
```

## Running Synchronization

Enqueue a synchronization using Sidekiq:

```bash
docker compose exec -T web bin/rails runner 'ProgrammeSyncJob.perform_later(generation: 1)'
```

Test upstream changes using the second dataset:

```bash
docker compose exec -T web bin/rails runner 'ProgrammeSyncJob.perform_later(generation: 2)'
```

The mock API supports additional scenarios:

| Parameter | Behavior |
|---|---|
| `generation=1` | Original dataset (60 screenings) |
| `generation=2` | Updated films, venues, screenings, and cancellations |
| `fail_after=8` | Simulates a partial response followed by HTTP 500 |
| `slow=true` | Simulates a slow API response |

Each execution attempt creates a `SyncRun` record containing its status, timestamps, processed pages, counters, and error details.

Scheduling is delegated to an external scheduler. For example, a host cron entry can enqueue the job nightly at 02:00:

```cron
0 2 * * * cd /absolute/path/to/festival-programme-sync && /usr/bin/docker compose exec -T web bin/rails runner 'ProgrammeSyncJob.perform_later(generation: 1)'
```

The host must have Docker access, and the application containers must be running. Cron enqueues the job; Sidekiq performs the synchronization.

## Implementation Notes

### Technical Decisions

- **Idempotent imports:** Films, venues, and screenings are matched by stable external IDs. Existing records are updated rather than duplicated.
- **Partial failure handling:** Each screening is imported within its own database transaction. Successfully committed records remain available if a later API request fails.
- **Background processing:** Active Job and Sidekiq handle asynchronous execution. Transient failures are retried up to three attempts, 30 seconds apart; deterministic errors are not automatically retried.
- **Observability:** `SyncRun` records execution outcomes, created/updated/unchanged counts, completed pages, and failures.
- **Concurrency:** A PostgreSQL session-level advisory lock prevents overlapping synchronizations across worker processes. The lock is held for the entire sync without keeping a database transaction open during HTTP requests. Overlapping executions are skipped.
- **Hotwire UI:** Turbo Frames update only the screenings results. Date, venue, and case-insensitive title filters can be combined, while eager loading prevents N+1 queries.

### Assumptions and Trade-offs

- The upstream API is the source of truth for record attributes, but it does not explicitly define deletion semantics. Screenings missing from a response are intentionally retained rather than automatically deleted.
- Partial imports are acceptable because subsequent executions are idempotent.
- Periodic scheduling uses external cron rather than an additional scheduling dependency. Skipped overlapping jobs are not automatically rescheduled.

### With More Time

- Add monitoring and alerting for failed or skipped synchronizations.
- Define an explicit removal or archival policy for screenings absent from upstream data.
- Consider batch imports and more scalable progress tracking for larger datasets.
- Refactor the existing `VenueSync` service to match venues by external ID rather than name, preventing incorrect behavior when venues are renamed.

## Tests

Run the complete RSpec suite:

```bash
make test
```

Tests cover API failures and pagination, idempotency, partial imports, changes between generations, execution tracking, retries, concurrency protection, filtering, Turbo Frame responses, and N+1 prevention.

## Submission

Private Git repository with incremental commits preserved.
