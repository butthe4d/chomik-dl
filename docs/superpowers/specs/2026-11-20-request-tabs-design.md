# chomik-dl — tabbed request list, requester filter, name suggestions

Date: 2026-11-20
Status: approved (user, 2026-11-20)
Size: small change (front-end only)

## Intent

With only a few requests the single list is already messy. Split it into
tabs by state, let people filter by who asked, and make typing your name
faster by suggesting recent names.

## Goals

- Both pages (family `/` and admin `/admin`) show the list in **5 tabs**,
  each with a count of the rows it holds (after the requester filter):
  1. **Czeka na akceptację** — `waiting`
  2. **Zaakceptowane** — `queued`, `resolving`, `downloading` (progress bar)
  3. **Pobrane** — `done`
  4. **Błędy** — `failed` (admin keeps "Ponów")
  5. **Odrzucone** — `rejected`
- **Requester filter:** a dropdown "Kto prosił" with "wszyscy" (default) and
  every distinct name found in the loaded requests' `requested_by`
  (split on ", ", sorted). A request asked for by several people shows under
  each of their names. Requests with no name only show under "wszyscy".
- **Name suggestions:** the name field on both forms that have one offers
  (native `<datalist>`) the 5 most recent distinct names from the loaded
  requests, newest first. The browser's own remembered name still pre-fills
  the field as today.
- Both pages open on *Czeka na akceptację*; each browser remembers its last
  tab and filter per page (localStorage, wrapped in try/catch — the page works
  without it).
- Polling every 2 s keeps working: tab, filter, expanded descriptions and the
  name being typed are never reset by a refresh.

## Non-goals

- Server-side filtering, paging or new API parameters (approach B).
- Searching by file name; sorting options.

## Constraints

- Tabs and filter work only on what `GET /requests` returns (newest 100 +
  every waiting request). Accepted: very old downloads drop out of
  *Pobrane* and its count.
- Keep the existing rule: all looked-up text rendered with `textContent`
  only (the no-`innerHTML` test covers the shared script).
- Phone width: tabs wrap or scroll horizontally, no page-wide horizontal
  scroll.

## Approaches (user picked A)

- **A. Browser-side — chosen.** Tabs, counts, filter and suggestions computed
  in `app/static/requests.js` from the data the page already polls. Small,
  no server change. Trade-off: limited to the loaded rows.
- B. Server-side filtering with paging — correct for thousands of rows,
  ~3× the work; not needed at family scale (raise the 100 limit first if it
  ever matters).

## Left to the builder

Exact tab styling (reuse the page's CSS variables and dark mode), keyboard
accessibility of tabs (buttons with `aria-selected`), how the filter dropdown
keeps its selection when the name list changes, test approach (a small JS
unit test for the grouping/filter/suggestion helpers if practical, plus a
Playwright check of the rendered pages against the fake site).
