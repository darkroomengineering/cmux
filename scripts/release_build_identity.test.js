"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

// Public contract for scripts/release_build_identity.js:
//
//   deriveReleaseBuildIdentity({
//     eventName,
//     workflowRunId,
//     workflowRunAttempt,
//     upstreamRunId?,
//     upstreamRunAttempt?,
//   }) -> canonical positive decimal string
//
// A workflow_run identity is upstream CI run ID + three-digit upstream attempt
// + three-digit downstream release attempt. Push/tag identities use the
// current workflow run ID + fixed source attempt 001 + fixed downstream slot
// 001, so a workflow rerun reuses its immutable artifact identity. Manual
// identities use the current workflow run ID + 001 + the three-digit current
// attempt. IDs remain decimal strings and are never converted through Number.
const { deriveReleaseBuildIdentity } = require("./release_build_identity");

test("workflow_run identities remain upstream-bound while downstream rebuilds are distinct", () => {
  const base = {
    eventName: "workflow_run",
    upstreamRunId: "900719925474099312345678901234567890",
    upstreamRunAttempt: "17",
    workflowRunId: "999999999999999999999999999999999999",
  };

  assert.equal(
    deriveReleaseBuildIdentity({ ...base, workflowRunAttempt: "1" }),
    "900719925474099312345678901234567890017001",
  );
  assert.equal(
    deriveReleaseBuildIdentity({ ...base, workflowRunAttempt: "2" }),
    "900719925474099312345678901234567890017002",
  );
});

test("historical workflow reruns cannot substitute the downstream release run ID", () => {
  const identity = deriveReleaseBuildIdentity({
    eventName: "workflow_run",
    upstreamRunId: "123456789012345678901234567890",
    upstreamRunAttempt: "3",
    workflowRunId: "987654321098765432109876543210",
    workflowRunAttempt: "4",
  });

  assert.equal(identity, "123456789012345678901234567890003004");
  assert.ok(!identity.startsWith("987654321098765432109876543210"));
});

test("push/tag workflow reruns reuse one immutable artifact identity", () => {
  const workflowRunId = "900719925474099312345678901234567891";
  const first = deriveReleaseBuildIdentity({
    eventName: "push",
    workflowRunId,
    workflowRunAttempt: "1",
  });
  const rerun = deriveReleaseBuildIdentity({
    eventName: "push",
    workflowRunId,
    workflowRunAttempt: "2",
  });

  assert.equal(first, `${workflowRunId}001001`);
  assert.equal(rerun, first);
});

test("manual identities use the current run and current attempt", () => {
  assert.equal(
    deriveReleaseBuildIdentity({
      eventName: "workflow_dispatch",
      workflowRunId: "900719925474099312345678901234567891",
      workflowRunAttempt: "9",
    }),
    "900719925474099312345678901234567891001009",
  );
});

test("run IDs are canonical positive decimal strings and stay BigInt-safe", async (t) => {
  for (const runId of ["0", "00", "01", "+1", "-1", "1e3", "1.5", "", 42]) {
    await t.test(JSON.stringify(runId), () => {
      assert.throws(
        () => deriveReleaseBuildIdentity({
          eventName: "workflow_dispatch",
          workflowRunId: runId,
          workflowRunAttempt: "1",
        }),
        /run|id|canonical|positive|decimal|string/i,
      );
    });
  }
});

test("source and workflow attempts must be decimal integers from 1 through 999", async (t) => {
  for (const attempt of ["0", "000", "1000", "1.0", "+1", " 1", "", 1]) {
    await t.test(`workflow ${JSON.stringify(attempt)}`, () => {
      assert.throws(
        () => deriveReleaseBuildIdentity({
          eventName: "workflow_dispatch",
          workflowRunId: "41",
          workflowRunAttempt: attempt,
        }),
        /attempt|integer|decimal|1|999|string/i,
      );
    });
  }

  for (const attempt of ["0", "1000", "01", "1.0", 1]) {
    await t.test(`upstream ${JSON.stringify(attempt)}`, () => {
      assert.throws(
        () => deriveReleaseBuildIdentity({
          eventName: "workflow_run",
          upstreamRunId: "41",
          upstreamRunAttempt: attempt,
          workflowRunId: "99",
          workflowRunAttempt: "1",
        }),
        /upstream|attempt|integer|decimal|1|999|string/i,
      );
    });
  }
});

test("unsupported events and incomplete workflow_run inputs fail closed", () => {
  assert.throws(
    () => deriveReleaseBuildIdentity({ eventName: "schedule", workflowRunId: "41", workflowRunAttempt: "1" }),
    /event|unsupported/i,
  );
  assert.throws(
    () => deriveReleaseBuildIdentity({
      eventName: "workflow_run",
      workflowRunId: "41",
      workflowRunAttempt: "1",
    }),
    /upstream|run|attempt|required/i,
  );
});
