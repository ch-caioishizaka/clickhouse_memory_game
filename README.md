# ClickHouse Memory Game (*Juego de memoria*)

A single-page memory game built for a ClickHouse event booth. Visitors fill in a
short lead form, play one timed round (9 pairs, one attempt per email), and see a
live leaderboard. The top *N* times win a prize.

The UI is in **Spanish** (it was built for the Chile event). Code comments are in
Spanish too.

There is no build step and no backend of our own: it's one static HTML file that
talks directly to two managed services.

| Piece | What it does | Where it's configured |
|---|---|---|
| **ClickHouse Cloud** (Query Endpoints) | Stores leads and times, serves the leaderboard | `CONFIG.ch` in `index.html`, SQL in `sql/schema.sql` |
| **ClickStack** (HyperDX browser SDK) | Session replay, console capture and custom events (`par_encontrado`, `partida_completada`, ...) | `CONFIG.hdxKey` / `hdxUrl` / `hdxService` in `index.html` |
| **GitHub Pages** | Hosts the page | Repo settings → Pages |

## Repo layout

```text
index.html        The game. All config lives in the CONFIG block near the top of the <script>.
qr.html           Poster generator: type the game URL, get a printable A4 poster with a QR code.
qr.svg            A pre-generated QR for the original URL.
sql/schema.sql    Table DDL, grants, the 5 Query Endpoint queries, and reporting queries.
```

## Run it locally

```sh
python3 -m http.server 8000
# open http://localhost:8000/?demo=1
```

- `?demo=1` forces **demo mode**: nothing is read from or written to ClickHouse, and
  the leaderboard is kept in `localStorage`. ClickStack telemetry still fires
  (tagged `demo: "true"`), so this is the safest way to test a new ClickStack key.
- `?reset=1` clears this browser's saved result. Without it, a browser that already
  finished a game goes straight to its result screen.
- Serve over `http://localhost`, not `file://`, so requests carry a real origin.
- Without `?demo=1`, ClickHouse calls from `localhost` only work if
  `http://localhost:8000` is in the endpoints' CORS allowed domains.

## Getting it working again

Work through these in order. Step 1 is the known blocker; the others are things that
commonly go stale after an event, so check them before assuming only the key is wrong.

### 1. Push a new ClickStack key

The game reads the ClickStack ingestion key from `CONFIG.hdxKey` in `index.html`.
The key is public by design (it ships in the HTML), and the comment next to it says to
rotate it after the event, so the old one has most likely been revoked.

> **Failure is silent.** If the key is bad, the game still works and nothing in the UI
> tells you. The only symptom is that no sessions show up in ClickStack.

1. **Get a new ingestion key** from ClickStack. Open the ClickStack UI for the
   ClickHouse Cloud service and look under the team / API key settings for the
   **Ingestion API Key**. Menu names vary between ClickStack versions. Use an
   **ingest-only** key, never a personal access key.
2. **Confirm the OTLP URL** in `CONFIG.hdxUrl`. It is the HTTP collector endpoint of
   the ClickHouse Cloud service (port `4318`). If the service was recreated, the host
   will most likely have changed, so update it too.
3. **Edit `index.html`**:

   ```js
   hdxKey:     "<new ingestion key>",
   hdxUrl:     "https://<service-id>.otel.<region>.aws.clickhouse.cloud:4318",
   hdxService: "memoria-clickhouse-web"   // the service name you'll filter on in ClickStack
   ```

4. **Test locally** at `http://localhost:8000/?demo=1`. Open DevTools → Network, filter
   on `otel`, and click through the form. Calls to the collector should return `200`.
   `401`/`403` means the key is wrong. Calls blocked by CORS or never sent mean the URL
   is wrong or the SDK script didn't load (see Troubleshooting).
5. **Confirm in ClickStack**: search service `memoria-clickhouse-web` and find the
   session (the `sessionId` attribute is also written to `evento.partidas.session_id`).
6. **Commit and push** (see [Deploy](#4-deploy)). GitHub Pages takes a minute or two.
   Hard-refresh on a phone, or use a private tab, to avoid the cached copy.

Do **not** put the key in a separate file or `.env`. There's no build step, so it
would never reach the browser.

### 2. Check the ClickHouse Cloud side

The game works without ClickStack but not without these. If the form hangs on
"Verificando", or the result screen says *"Tu tiempo no llegó al servidor"*, start here.

1. **Service is running.** Idle or paused services need to be started in the Cloud
   console. If the service was deleted, you'll have to recreate everything below.
2. **Schema exists.** In the SQL console, run everything in `sql/schema.sql` above the
   `ENDPOINT 1` banner: database, `evento.partidas`, the idempotent `ADD COLUMN`s, the
   async-insert settings and the `GRANT`s. Grants are **per column**, so re-run them
   whenever a column is added. The `ALTER USER` / `GRANT` statements target a user
   named `juego_evento`. Change that to whatever user or role your endpoints run as.
3. **Endpoints exist.** There are five. Each is a saved query from `sql/schema.sql`,
   shared via **Share → API Endpoint**. When creating one, choose the API key allowed to
   call it, a database role (endpoints 1 and 2 are `INSERT`s, so **Read only** won't
   work), and the CORS allowed domains (see step 4).
4. **API key.** The code authenticates with HTTP Basic auth, `key:secret`, in
   `CONFIG.ch.key` / `CONFIG.ch.secret`. Create a new OpenAPI key in the Cloud console
   if the old one was rotated. Per the
   [Query Endpoints docs](https://clickhouse.com/docs/products/cloud/guides/sql-console/query-endpoints)
   it needs the **Member** org role with **Query Endpoints** service access, and it
   must be added to each endpoint's allowed keys.
5. **Copy the new endpoint IDs** into `CONFIG.ch.ep` (the table below says which is
   which).

| `CONFIG.ch.ep` key | SQL in `schema.sql` | Called when | Params |
|---|---|---|---|
| `registro` | ENDPOINT 1 | Form submitted | evento, correo, nombre, apellido, telefono, empresa, industria, empleados, session_id |
| `tiempo` | ENDPOINT 2 | Game finished (re-inserts the full row) | all of the above + elapsed_ms, flips, fallos |
| `top` | ENDPOINT 3 | Leaderboard | evento, limite |
| `posicion` | ENDPOINT 4 | Result screen (rank and total) | evento, correo |
| `yaJugo` | ENDPOINT 5 | Before playing (one attempt per email) | evento, correo |

Test an endpoint outside the browser, mirroring what `chq()` does:

```sh
curl -sS --user "$CH_KEY:$CH_SECRET" \
  "https://queries.clickhouse.cloud/run/<endpoint-id>?format=JSONEachRow&param_evento=Stand%20ClickHouse&param_limite=8"
```

An empty body or `OK` is fine for an empty table or an `INSERT`. `403 Not enough privileges`
means missing `GRANT`s. A `400` usually means a missing `param_*` (the app always sends
every parameter, even if empty).

> If the old `queries.clickhouse.cloud/run/<id>` host no longer resolves, note that the
> current docs show the format `https://console-api.clickhouse.cloud/.api/query-endpoints/<id>/run`.
> The URL is built in `chq()` in `index.html`.

### 3. Configure for the (new) event

Edit the `CONFIG` block in `index.html`:

- **`eventLabel`** is written to the `evento` column. Everything is scoped by it:
  the leaderboard, the "one attempt per email" check and the reports. Keep the old
  value and previous participants are blocked and the old leaderboard comes back. Use a
  new value for a fresh event.
- **`prizeCount`** is how many positions are shown and win a prize. The `top` endpoint
  takes it as `UInt8`.
- **Prize pick-up time** ("14:00 del día 09") is hard-coded in the result screen and the
  footer of `index.html`, and in the footer of `qr.html`. Search for `14:00`.
- `trialUrl` is defined in `CONFIG` but **not used** anywhere right now.
- Test-only: a phone that already played shows its saved result. Add `?reset=1` to
  the URL to clear it.

### 4. Deploy

The site is served from GitHub Pages. The original repo is
`ch-caioishizaka/clickhouse_memory_game`, published at
`https://ch-caioishizaka.github.io/clickhouse_memory_game/`.

1. You need push access to that repo. If you don't have it, fork the repo, enable
   **Settings → Pages → Deploy from branch → `main` / root** on the fork, and use the
   fork's URL from here on.
2. `git push origin main`, then wait for the Pages build to finish.
3. **Add the Pages origin to each endpoint's CORS allowed domains**
   (`https://<user>.github.io`, with no path). Without it the browser blocks every
   ClickHouse call even when the credentials are fine.
4. **If the URL changed**, reprint the poster: open `qr.html`, paste the new URL, and
   use *Imprimir / PDF*. The optional *origen* field appends `?src=...`, so you can
   print one poster per location and see which one drives traffic in ClickStack.
   `qr.svg` is a static QR for the old URL, so don't reuse it.

### 5. Smoke test the live site

1. Open the deployed URL on a phone, with `?reset=1` on the first load.
2. Fill the form with a throwaway email, play a round, and check the result screen
   shows a rank (*"Posición: N° de M"*), not the *"Tu tiempo no llegó al servidor"* error.
3. In ClickHouse: `SELECT * FROM evento.partidas FINAL WHERE evento = '<eventLabel>'`
   should show the row with `elapsed_ms > 0`.
4. In ClickStack, the same session should appear with replay and the custom events.
5. Test rows count on the real leaderboard. Use a throwaway `eventLabel` while testing,
   then switch to the real one before the event, or remove the rows as an admin.

## End of day: produce the leaderboard

The on-screen table only shows `Name + initial` and a time, which is not enough to
contact winners. The full list comes from `evento.partidas`. Do this **before** you rotate
or revoke the keys at the end of the event (see [Security notes](#security-notes)).

1. **Pick the cutoff.** The game has no "close" switch, so a round finished after your
   export is still saved and can change the ranking. Note the time of the export, or
   filter on it (see the optional lines in the query below).
2. **Make sure the ClickHouse service is running**, then open the SQL console.
3. **Run the winners query**, replacing the two literals with `CONFIG.eventLabel` and
   `CONFIG.prizeCount` from `index.html`:

   ```sql
   SELECT
       row_number() OVER (ORDER BY elapsed_ms ASC, registrado ASC) AS pos,
       nombre, apellido, correo, telefono, empresa,
       elapsed_ms,
       round(elapsed_ms / 1000, 3) AS seconds,
       flips, fallos
   FROM evento.partidas FINAL
   WHERE evento = 'Stand ClickHouse'        -- CONFIG.eventLabel
     AND elapsed_ms > 0                     -- 0 = registered but never finished
     -- Optional: only one day, if the same eventLabel ran for several days
     -- AND toDate(registrado, 'America/Santiago') = 'YYYY-MM-DD'
     -- Optional: ignore anything saved after the cutoff
     -- AND registrado <= toDateTime64('YYYY-MM-DD HH:MM:SS', 3, 'America/Santiago')
   ORDER BY pos
   LIMIT 8;                                 -- CONFIG.prizeCount
   ```

   Keep `FINAL`. Each person has up to two rows (registered, then finished), and
   `FINAL` returns only the latest version. Without it you can get duplicates or the
   unfinished row. For the full ranking, raise or remove the `LIMIT`.
4. **Sanity-check the result.**
   - It should match the in-app table: open the game in a fresh browser and check the
     names and times (the table shows the first letter of the last name only).
   - Ties are broken here by the earlier `registrado` (the time the finishing row was
     written). The app's own rank doesn't break ties, so check the cutoff position by
     hand and apply the event's own tie rule if it has one.
   - Winners can prove it on their phone: their result screen shows *Elapsed* and
     *Posición*, and it should match `seconds` and `correo`.
5. **Export it.** Download the result as CSV from the SQL console's results pane (the
   menu name may vary), or run the same query from `clickhouse client` with
   `--format CSVWithNames > winners.csv`.
6. **Catch missing times.** Someone whose time didn't reach the server was told to show
   their screen to the booth staff. Their row normally exists from registration, but with
   `elapsed_ms = 0`. If registration also failed, there is no row and the screen they
   showed is the only record:

   ```sql
   SELECT nombre, apellido, correo, telefono, registrado
   FROM evento.partidas FINAL
   WHERE evento = 'Stand ClickHouse' AND elapsed_ms = 0
   ORDER BY registrado;
   ```

7. **Run the other reports** in the last section of `sql/schema.sql` (*Consultas para el
   stand / seguimiento*) for the day's wrap-up: registration-to-finish funnel, the full
   lead list for marketing/Salesforce, and leads by industry and company size. Replace
   `{evento:String}` with the same `eventLabel` literal. `industria` is already stored in
   the English values Salesforce expects.

Only after the export is saved should you rotate the keys, since rotating cuts the game
off from the table.

## Security notes

Everything in `CONFIG` is readable by anyone who opens the page's source.

- Keep the ClickStack key **ingest-only**, and the ClickHouse API key limited to
  **only these five endpoints**. Rotate both when the event ends, after the
  [end-of-day export](#end-of-day-produce-the-leaderboard).
- The key, secret, endpoint IDs and ClickStack key currently committed in `index.html`
  are also in **git history**. Treat them as burned and don't reuse them. Rotating at
  the end of an event makes history harmless, so don't skip that step.
- `.gitignore` covers `.env`, `*api-key*`, `*.secret` and `credentials*`, but none of
  those protect `index.html`, since the credentials live inside it.
- The form collects personal data (name, email, phone, company). ClickStack replay masks
  inputs (`maskAllInputs`), and `userEmail` / `userName` are attached to the session on
  purpose. Delete that `setGlobalAttributes` call in `screenForm()` if you want
  anonymous telemetry.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Game works, but nothing appears in ClickStack | Bad or revoked `hdxKey`, wrong `hdxUrl`, or the SDK script failed to load. Check DevTools → Network for the `@hyperdx/browser` script and the collector calls. |
| `window.HyperDX` is undefined | The SDK is loaded from `unpkg.com` (`@hyperdx/browser@0.21.0`). A blocked or slow CDN, such as venue wifi, silently disables telemetry. The game itself keeps working. |
| "Este correo ya participó" for a new tester | That email already has `elapsed_ms > 0` for this `eventLabel`. Change `eventLabel` or delete the row. |
| "Tu tiempo no llegó al servidor" | The `tiempo` endpoint failed: service idle, CORS missing, bad credentials or missing grants. The player can tap *Enviar mi tiempo* to retry. |
| 403 "Not enough privileges" | `GRANT`s are per column. Re-run them from `schema.sql` after adding columns. |
| Result screen says "Modo demo: la tabla es local..." | `CONFIG.ch.key` is empty, or the URL has `?demo`. Nothing is saved to ClickHouse. |
| Leaderboard shows duplicate names | The table shows `Name + initial`, so two "Camila R." look identical. The ranking itself is exact. |
| Old result keeps showing on one phone | `localStorage`. Open the URL once with `?reset=1`. |
