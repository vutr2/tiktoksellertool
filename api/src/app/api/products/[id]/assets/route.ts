import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { json, error } from "@/lib/http";
import { languageFromHeader } from "@/lib/i18n";
import { localizeFailures } from "@/lib/generate";
import { assetLanguages, type StoredGenerationResult } from "@/lib/asset-provenance";

interface StoredResult extends StoredGenerationResult {
  failures?: { marketplace: string; reason: string }[];
}

/**
 * The generated assets for one product, with their stored compliance results.
 *
 * This is what makes a listing reopenable: credits were charged, so the work
 * must still be there after the app is closed (Guideline 2.1).
 */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  const { id } = await context.params;
  const db = supabaseAdmin();

  // Ownership is checked on the product, not the asset: an asset row carries no
  // org, so querying it directly would leak another seller's listing.
  const { data: product } = await db
    .from("products")
    .select("id, name, category")
    .eq("id", id)
    .eq("org_id", claims.orgId)
    .maybeSingle();
  if (!product) return error("That product could not be found.", 404);

  const { data, error: dbError } = await db
    .from("assets")
    .select("id, type, marketplace, content, validation_status, violations, created_at")
    .eq("product_id", id)
    .neq("marketplace", "source")
    .order("created_at", { ascending: true });
  if (dbError) return error("Could not load this listing.", 500);

  // Every completed generation, not just the newest. Asset rows accumulate
  // across generations — `complete_generation` inserts new ones and keeps the
  // old — so a product can hold Vietnamese copy from one run beside English
  // copy from the next. One language for the whole product would mislabel the
  // work the seller already paid for, and the free rules check would then
  // report unchecked Vietnamese copy as clean.
  const { data: completed, error: latestError } = await db.from("generation_requests")
    .select("result, completed_at").eq("org_id", claims.orgId).eq("product_id", id)
    .eq("status", "completed").order("completed_at", { ascending: false });
  if (latestError) return error("Could not load the generation result.", 503);

  const history = (completed ?? []) as { result: StoredResult | null }[];
  const languageOf = assetLanguages(history);
  const latest = history[0] ?? null;

  // Reopening a listing is the other path a partial failure reaches the seller
  // through, and it is a 200 too. Reasons are stored in English and translated
  // here on read, so a listing opened after switching language arrives in the
  // new one. `language` is what the copy itself is written in — a different
  // thing, and what the free rules check needs to judge it honestly.
  const stored = localizeFailures(
    { failures: (latest?.result?.failures ?? []) as { marketplace: string; reason: string }[] },
    languageFromHeader(request.headers.get("accept-language")),
  );

  return json({
    failures: stored.failures,
    language: latest?.result?.language ?? "en",
    product: { id: product.id, name: product.name, category: product.category ?? null },
    assets: (data ?? []).map((row) => ({
      id: row.id as string,
      type: row.type as string,
      marketplace: row.marketplace as string,
      content: (row.content as string | null) ?? "",
      status: row.validation_status as string,
      violations: row.violations ?? [],
      // Absent when this row is in no stored result — a script written through
      // its own endpoint, or work older than result storage. Absent is not
      // English: the caller decides what to do with an unknown origin rather
      // than being handed the newest request's language as if it were a fact.
      language: languageOf.get(row.id as string),
    })),
  });
}
