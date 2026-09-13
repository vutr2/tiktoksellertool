// The credit ledger (SPEC §6 and §9).
//
// Two rules shape everything here:
//
//   "credit_ledger is append-only. Never UPDATE. Balance is derived."
//   "Check balance before dispatching a generation, charge on success only."
//
// So there is no `setBalance`. A correction is another row, and the history
// stays intact — Apple refund disputes are the reason.

import { supabaseAdmin } from "./supabase.ts";

/** Costs from SPEC §6. TODO(M5): serve from config/credits.json. */
export const CREDIT_COST = {
  titleOrDescription: 1,
  adScript: 2,
  imageGeneration: 5,
  /** Deliberately free — it is the hook (SPEC §6). */
  marketplaceConversion: 0,
} as const;

export type LedgerReason =
  | "generation.title"
  | "generation.description"
  | "generation.script"
  | "generation.image"
  | "generation.refund"
  | "subscription.grant"
  | "topup.purchase"
  | "refund.reversal";

export interface LedgerEntry {
  delta: number;
  reason: LedgerReason;
  balanceAfter: number;
  createdAt: string;
}

export interface BalanceReport {
  /** Authoritative: the sum of every delta. */
  balance: number;
  /** What the newest row recorded. Should equal `balance`. */
  recordedBalanceAfter: number | null;
  /** True when the two disagree — a real integrity problem, not a rounding one. */
  drifted: boolean;
  entryCount: number;
}

/**
 * Derives the balance by summing the ledger, and cross-checks it against the
 * newest row's `balance_after`.
 *
 * Summing is what SPEC §9 means by "balance is derived"; the stored column is
 * an audit convenience. Comparing them turns a silent accounting drift into
 * something visible.
 *
 * TODO(M5): this reads every row. Fine at current volumes, not at scale — move
 * to a Postgres aggregate once the schema may change again.
 */
export async function balanceOf(orgId: string): Promise<BalanceReport> {
  const db = supabaseAdmin();
  const { data, error } = await db
    .from("credit_ledger")
    .select("delta, balance_after, created_at")
    .eq("org_id", orgId)
    .order("created_at", { ascending: true });
  if (error) throw new Error(error.message);

  const rows = data ?? [];
  const balance = rows.reduce((sum, row) => sum + Number(row.delta), 0);
  const recorded = rows.length ? Number(rows[rows.length - 1].balance_after) : null;

  return {
    balance,
    recordedBalanceAfter: recorded,
    drifted: recorded !== null && recorded !== balance,
    entryCount: rows.length,
  };
}

/**
 * Appends one entry. The only way the ledger ever changes.
 *
 * `balance_after` is computed from the derived balance so the column stays
 * meaningful. Two concurrent appends can still race on it; the summed balance
 * remains correct either way, which is why the sum is the source of truth.
 * TODO(M5): serialise this in a Postgres function once billing goes live.
 */
export async function appendEntry(
  orgId: string,
  delta: number,
  reason: LedgerReason,
  originalTransactionId?: string,
): Promise<LedgerEntry> {
  if (!Number.isInteger(delta)) throw new Error("Credit deltas must be whole credits.");
  if (delta === 0) throw new Error("A zero-credit entry records nothing.");

  const db = supabaseAdmin();
  const current = await balanceOf(orgId);
  const balanceAfter = current.balance + delta;

  const { data, error } = await db
    .from("credit_ledger")
    .insert({
      org_id: orgId,
      delta,
      reason,
      balance_after: balanceAfter,
      original_transaction_id: originalTransactionId ?? null,
    })
    .select("delta, reason, balance_after, created_at")
    .single();
  if (error) throw new Error(error.message);

  return {
    delta: Number(data.delta),
    reason: data.reason as LedgerReason,
    balanceAfter: Number(data.balance_after),
    createdAt: data.created_at as string,
  };
}

/** Raised when a generation is refused for lack of credits. */
export class InsufficientCreditsError extends Error {
  readonly required: number;
  readonly available: number;

  constructor(required: number, available: number) {
    super(`This needs ${required} credits and you have ${available}.`);
    this.name = "InsufficientCreditsError";
    this.required = required;
    this.available = available;
  }
}

/**
 * Confirms the org can afford the work — before it is dispatched.
 *
 * Nothing is written here. SPEC §6: "Check balance before dispatching a
 * generation, charge on success only."
 */
export async function assertCanAfford(orgId: string, credits: number): Promise<void> {
  if (credits <= 0) return;
  const { balance } = await balanceOf(orgId);
  if (balance < credits) throw new InsufficientCreditsError(credits, balance);
}

/** Charges after the work succeeded. A free action writes nothing at all. */
export async function chargeCredits(
  orgId: string,
  credits: number,
  reason: LedgerReason,
): Promise<LedgerEntry | null> {
  if (credits <= 0) return null;
  return appendEntry(orgId, -credits, reason);
}

/**
 * Gives credits back for work that failed after being charged.
 *
 * A reversal is a new row, never a deletion — SPEC §12 lists mutating credits
 * with UPDATE as a defect.
 */
export async function refundCredits(orgId: string, credits: number): Promise<LedgerEntry | null> {
  if (credits <= 0) return null;
  return appendEntry(orgId, credits, "generation.refund");
}
