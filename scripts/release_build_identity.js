"use strict";

const CANONICAL_POSITIVE_DECIMAL = /^[1-9][0-9]*$/;

function assertPositiveDecimal(value, label) {
  if (typeof value !== "string" || !CANONICAL_POSITIVE_DECIMAL.test(value)) {
    throw new TypeError(`${label} must be a canonical positive decimal string`);
  }
}

function paddedAttempt(value, label) {
  assertPositiveDecimal(value, label);
  if (BigInt(value) > 999n) {
    throw new RangeError(`${label} must be between 1 and 999`);
  }
  return value.padStart(3, "0");
}

function deriveReleaseBuildIdentity({
  eventName,
  upstreamRunId,
  upstreamRunAttempt,
  workflowRunId,
  workflowRunAttempt,
}) {
  assertPositiveDecimal(workflowRunId, "workflow run id");
  const downstreamAttempt = paddedAttempt(workflowRunAttempt, "workflow run attempt");

  if (eventName === "workflow_run") {
    assertPositiveDecimal(upstreamRunId, "upstream run id");
    const upstreamAttempt = paddedAttempt(upstreamRunAttempt, "upstream run attempt");
    return `${upstreamRunId}${upstreamAttempt}${downstreamAttempt}`;
  }
  if (eventName === "push") {
    return `${workflowRunId}001001`;
  }
  if (eventName === "workflow_dispatch") {
    return `${workflowRunId}001${downstreamAttempt}`;
  }
  throw new TypeError(`unsupported release event: ${String(eventName)}`);
}

module.exports = { deriveReleaseBuildIdentity };
