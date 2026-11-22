# Farside backend

Accounts, device registry, signaling relay, presence and TURN credentials (plan section 13).
It never sees session content.

- `make server-test`: tests on SQLite in memory, and the formatter.
- `make server-up`: PostgreSQL, Redis, the API on http://localhost:47880 and Reverb on
  ws://localhost:47881, with Docker Compose. Needs `.env`, made from `.env.example`.
