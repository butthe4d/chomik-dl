const test = require("node:test");
const assert = require("node:assert/strict");
const L = require("../../app/static/list-logic.js");

const job = (id, status, requested_by = "") => ({id, status, requested_by});

test("TABS order, labels and statuses", () => {
  assert.deepEqual(L.TABS.map(t => [t.id, t.label, t.statuses]), [
    ["waiting", "Czeka na akceptację", ["waiting"]],
    ["approved", "Zaakceptowane", ["queued", "resolving", "downloading"]],
    ["done", "Pobrane", ["done"]],
    ["failed", "Błędy", ["failed"]],
    ["rejected", "Odrzucone", ["rejected"]],
  ]);
});

test("tabOf maps statuses, unknown is null", () => {
  assert.equal(L.tabOf("resolving"), "approved");
  assert.equal(L.tabOf("downloading"), "approved");
  assert.equal(L.tabOf("done"), "done");
  assert.equal(L.tabOf("weird"), null);
});

test("namesOf splits and trims, drops empty", () => {
  assert.deepEqual(L.namesOf({requested_by: " Ania ,  Tomek"}), ["Ania", "Tomek"]);
  assert.deepEqual(L.namesOf({requested_by: ""}), []);
  assert.deepEqual(L.namesOf({}), []);
});

test("requesters distinct and pl-sorted", () => {
  const jobs = [job(1, "done", "Ania"), job(2, "done", " Ania , Żaneta"), job(3, "done", "Zenek"), job(4, "done")];
  assert.deepEqual(L.requesters(jobs), ["Ania", "Zenek", "Żaneta"]);
});

test("filterByRequester: all, single, multi-name rows, unnamed only under all", () => {
  const jobs = [job(1, "done", "Ania"), job(2, "done", "Ania, Ola"), job(3, "done")];
  assert.equal(L.filterByRequester(jobs, "").length, 3);
  assert.deepEqual(L.filterByRequester(jobs, "Ola").map(j => j.id), [2]);
  assert.deepEqual(L.filterByRequester(jobs, "Ania").map(j => j.id), [1, 2]);
});

test("countByTab counts every tab, unknown ignored", () => {
  const jobs = [job(1, "waiting"), job(2, "queued"), job(3, "downloading"), job(4, "done"), job(5, "failed"), job(6, "rejected"), job(7, "weird")];
  assert.deepEqual(L.countByTab(jobs), {waiting: 1, approved: 2, done: 1, failed: 1, rejected: 1});
  assert.deepEqual(L.countByTab([]), {waiting: 0, approved: 0, done: 0, failed: 0, rejected: 0});
});

test("inTab filters and sorts newest first", () => {
  const jobs = [job(1, "queued"), job(5, "done"), job(3, "resolving")];
  assert.deepEqual(L.inTab(jobs, "approved").map(j => j.id), [3, 1]);
});

test("recentNames: 5 newest distinct", () => {
  const jobs = [job(1, "done", "A"), job(2, "done", "B"), job(3, "done", "C, D"), job(4, "done", "B"),
                job(5, "done"), job(6, "done", "E"), job(7, "done", "F")];
  assert.deepEqual(L.recentNames(jobs), ["F", "E", "B", "C", "D"]);
  assert.deepEqual(L.recentNames(jobs, 2), ["F", "E"]);
});

test("resolveRequester keeps saved only if available", () => {
  assert.equal(L.resolveRequester("Ola", ["Ania"]), "");
  assert.equal(L.resolveRequester("Ania", ["Ania"]), "Ania");
  assert.equal(L.resolveRequester(null, ["Ania"]), "");
});
