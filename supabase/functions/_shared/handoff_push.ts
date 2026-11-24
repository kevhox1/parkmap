/**
 * _shared/handoff_push.ts — pure payload builders + state gates for send-handoff-push (Spot Pass, spec 7.1/7.2/9).
 * No network and no esm imports: unit-tested offline in handoff_test.ts.
 *
 * PAYLOAD PRIVACY (spec 9 #5, #14): text only. No address, block, side, car, coordinates, no driver identity to the
 * seeker. `thanks` carries only the alias/first name the driver already saw. Custom keys are just {kind, handoff_id}.
 */

export type PushKind = "armed" | "departed" | "thanks" | "handoff_ended";
export const PUSH_KINDS: PushKind[] = ["armed", "departed", "thanks", "handoff_ended"];

export interface HandoffPushRow {
  id: string;
  status: string;
  seeker_id: string;
  alias: string;
  seeker_display_name: string | null;
  leave_at: string | null;
  outcome: string | null;
  claimer_push_token: string | null;
  claimer_activity_token: string | null;
  claimer_topic: string | null;
}

export function isPushKind(v: unknown): v is PushKind {
  return typeof v === "string" && (PUSH_KINDS as string[]).includes(v);
}

/** A push only goes out if the row is in the state that kind describes (guards stale / replayed dispatches). */
export function stateAllows(kind: PushKind, row: HandoffPushRow): boolean {
  switch (kind) {
    case "armed":
      return row.status === "armed";
    case "departed":
      return row.status === "departed";
    case "thanks":
      return row.status === "departed" && row.outcome === "got_spot";
    case "handoff_ended":
      return row.status === "cancelled" || row.status === "suspended";
  }
}

/** Whole minutes until leave_at rounded to 5; null when it is 5 or less (copy then says "soon"). */
export function approxMinutes(leaveAt: string | null, nowMs: number): number | null {
  if (!leaveAt) return null;
  const t = Date.parse(leaveAt);
  if (!Number.isFinite(t)) return null;
  const mins = Math.round((t - nowMs) / 60000 / 5) * 5;
  return mins > 5 ? mins : null;
}

/** iOS registers this notification category (NotificationCategoryRegistry.swift). Seeker visible alerts only. */
export const SEEKER_CATEGORY = "wepark_spot_pass_seeker";

export function seekerAlertBody(kind: "armed" | "departed", row: HandoffPushRow, nowMs: number): Record<string, unknown> {
  let body: string;
  if (kind === "armed") {
    const m = approxMinutes(row.leave_at, nowMs);
    body = m === null ? "A neighbor will be leaving soon." : `A neighbor will be leaving in about ${m} min.`;
  } else {
    body = "Your neighbor is pulling out now.";
  }
  return {
    aps: {
      alert: { title: "Spot Pass", body },
      sound: "default",
      "thread-id": "spot-pass",
      category: SEEKER_CATEGORY,
    },
    kind,
    handoff_id: row.id,
  };
}

/** Driver thank-you as a visible alert. For clip tokens `target-content-id` is REQUIRED by Apple for remote
 * notifications to a clip (must match a registered experience URL). */
export function driverThanksAlertBody(row: HandoffPushRow, isClip: boolean, clipUrl: string): Record<string, unknown> {
  const who = row.seeker_display_name || row.alias;
  const aps: Record<string, unknown> = {
    alert: { title: "Thanks, neighbor!", body: `${who} got your spot.` },
    sound: "default",
    "thread-id": "spot-pass",
  };
  if (isClip) aps["target-content-id"] = clipUrl;
  return { aps, kind: "thanks", handoff_id: row.id };
}

/** Silent push for a full-app driver: close the auto-detect window + Live Activity bookkeeping. */
export function silentEndedBody(row: HandoffPushRow): Record<string, unknown> {
  return { aps: { "content-available": 1 }, kind: "handoff_ended", handoff_id: row.id };
}

/** ActivityKit push-to-end. content-state keys are the contract with the iOS ContentState (see PR notes): {phase}. */
export function liveActivityEndBody(kind: "thanks" | "handoff_ended", row: HandoffPushRow, nowSec: number): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    timestamp: nowSec,
    event: "end",
    "content-state": { phase: kind === "thanks" ? "thanks" : "ended" },
    // thanks lingers on the lock screen for 10 minutes; ended clears right away.
    "dismissal-date": kind === "thanks" ? nowSec + 600 : nowSec,
  };
  if (kind === "thanks") {
    aps.alert = { title: "Thanks, neighbor!", body: `${row.seeker_display_name || row.alias} got your spot.` };
  }
  return { aps };
}

/** Topic for an ActivityKit push: `<bundle id>.push-type.liveactivity`. */
export function liveActivityTopic(bundleTopic: string): string {
  return `${bundleTopic}.push-type.liveactivity`;
}

/** The clip's bundle id is the app's plus ".Clip" (spec 5.2 #5). */
export function isClipTopic(topic: string, appTopic: string): boolean {
  return topic !== appTopic && topic.endsWith(".Clip");
}
