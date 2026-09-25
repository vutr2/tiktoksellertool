import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { json, error } from "@/lib/http";
import { languageFromHeader } from "@/lib/i18n";
import { localizeFailures } from "@/lib/generate";

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

  const { data: latest, error: latestError } = await db.from("generation_requests")
    .select("result").eq("org_id", claims.orgId).eq("product_id", id)
    .eq("status", "completed").order("completed_at", { ascending: false }).limit(1).maybeSingle();
  if (latestError) return error("Could not load the generation result.", 503);

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
    })),
  });
}
