// Pure helpers for the request list: tabs, requester filter, name suggestions.
// Loaded in the browser as the global `ListLogic` and require()-able from Node for tests.
(function (root) {
  const TABS = [
    {id: "waiting", label: "Czeka na akceptację", statuses: ["waiting"]},
    {id: "approved", label: "Zaakceptowane", statuses: ["queued", "resolving", "downloading"]},
    {id: "done", label: "Pobrane", statuses: ["done"]},
    {id: "failed", label: "Błędy", statuses: ["failed"]},
    {id: "rejected", label: "Odrzucone", statuses: ["rejected"]},
  ];

  function tabOf(status) {
    const t = TABS.find(t => t.statuses.includes(status));
    return t ? t.id : null;
  }

  function namesOf(job) {
    return (job.requested_by || "").split(",").map(s => s.trim()).filter(Boolean);
  }

  function requesters(jobs) {
    return [...new Set(jobs.flatMap(namesOf))].sort((a, b) => a.localeCompare(b, "pl"));
  }

  function filterByRequester(jobs, who) {
    return who ? jobs.filter(j => namesOf(j).includes(who)) : jobs;
  }

  function countByTab(jobs) {
    const counts = Object.fromEntries(TABS.map(t => [t.id, 0]));
    for (const j of jobs) { const t = tabOf(j.status); if (t) counts[t] += 1; }
    return counts;
  }

  function inTab(jobs, tabId) {
    return jobs.filter(j => tabOf(j.status) === tabId).sort((a, b) => b.id - a.id);
  }

  function recentNames(jobs, n = 5) {
    const out = [];
    for (const j of jobs.slice().sort((a, b) => b.id - a.id)) {
      for (const name of namesOf(j)) {
        if (!out.includes(name)) out.push(name);
        if (out.length === n) return out;
      }
    }
    return out;
  }

  function resolveRequester(saved, available) {
    return saved && available.includes(saved) ? saved : "";
  }

  const api = {TABS, tabOf, namesOf, requesters, filterByRequester, countByTab, inTab, recentNames, resolveRequester};
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.ListLogic = api;
})(this);
