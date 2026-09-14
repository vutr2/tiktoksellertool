import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { json, error } from "@/lib/http";

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
<<<<<<< HEAD
    .neq("marketplace", "source")
    .order("created_at", { ascending: true });
  if (dbError) return error("Could not load this listing.", 500);

  const { data: latest, error: latestError } = await db.from("generation_requests")
    .select("result").eq("org_id", claims.orgId).eq("product_id", id)
    .eq("status", "completed").order("completed_at", { ascending: false }).limit(1).maybeSingle();
  if (latestError) return error("Could not load the generation result.", 503);

  return json({
    failures: latest?.result?.failures ?? [],
=======
    .order("created_at", { ascending: true });
  if (dbError) return error("Could not load this listing.", 500);

  return json({
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
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
