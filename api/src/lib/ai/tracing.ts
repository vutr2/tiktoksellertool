// Langfuse tracing for model calls (SPEC §3: "Langfuse on all model calls").
//
// Tracing must never be the reason a generation fails. Without keys the call
// still runs and simply goes untraced — the same posture `email.ts` takes when
// RESEND_API_KEY is missing.

import { startActiveObservation } from "@langfuse/tracing";
import { langfuse } from "../env.ts";
import type { ModelUsage } from "./types.ts";

/** What the caller reports back after the model answered. */
export interface GenerationOutcome<T> {
  value: T;
  /** Recorded on the trace so a bad result can be read back later. */
  output: unknown;
  inputTokens: number;
  outputTokens: number;
  cachedInputTokens: number;
  /** Null when the model's rate is unknown — never guessed (see pricing.ts). */
  costUSD: number | null;
}

export interface GenerationContext {
  provider: ModelUsage["provider"];
  model: string;
  /** Prompt or image description. Never include secrets. */
  input: unknown;
  modelParameters?: Record<string, string | number>;
}

/**
 * Runs a model call and records it.
 *
 * Returns the value plus the `ModelUsage` a `generations` row needs (SPEC §9).
 * Latency is measured around the call itself, not around the tracing.
 */
export async function tracedGeneration<T>(
  name: string,
  context: GenerationContext,
  run: () => Promise<GenerationOutcome<T>>,
): Promise<{ value: T; usage: ModelUsage }> {
  const started = Date.now();

  if (!langfuse.isConfigured()) {
    const outcome = await run();
    return { value: outcome.value, usage: usageFrom(context, outcome, Date.now() - started, null) };
  }

  return startActiveObservation(
    name,
    async (generation) => {
<<<<<<< HEAD
      // Observability does not need customer photos, prompts or generated text.
      // Keep those out of a second processor's retention/deletion lifecycle.
      generation.update({ model: context.model, modelParameters: context.modelParameters });
=======
      generation.update({ input: context.input, model: context.model, modelParameters: context.modelParameters });
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196

      let outcome: GenerationOutcome<T>;
      try {
        outcome = await run();
      } catch (error) {
        // Record the failure before rethrowing: a generation that failed is
        // exactly the one worth reading later, and SPEC §6 says it must not be
        // charged for.
<<<<<<< HEAD
        generation.update({ level: "ERROR", statusMessage: "Provider request failed" });
=======
        generation.update({ output: { error: error instanceof Error ? error.message : String(error) } });
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
        throw error;
      }

      const latencyMs = Date.now() - started;
      generation.update({
<<<<<<< HEAD
=======
        output: outcome.output,
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
        usageDetails: {
          input: outcome.inputTokens,
          output: outcome.outputTokens,
          cache_read_input_tokens: outcome.cachedInputTokens,
        },
        ...(outcome.costUSD !== null ? { costDetails: { total: outcome.costUSD } } : {}),
      });

      const traceId = generation.traceId ?? null;
      return { value: outcome.value, usage: usageFrom(context, outcome, latencyMs, traceId) };
    },
    { asType: "generation" },
  );
}

function usageFrom<T>(
  context: GenerationContext,
  outcome: GenerationOutcome<T>,
  latencyMs: number,
  traceId: string | null,
): ModelUsage {
  return {
    provider: context.provider,
    model: context.model,
    inputTokens: outcome.inputTokens,
    outputTokens: outcome.outputTokens,
    cachedInputTokens: outcome.cachedInputTokens,
    // Stays null when the rate is unknown: "unrecorded", not "free".
    costUSD: outcome.costUSD,
    latencyMs,
    traceId,
  };
}
