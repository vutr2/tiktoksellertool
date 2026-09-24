import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import {
  createProduct,
  ensureCutoutBucket,
  validateCreateProduct,
  readLimitedBody,
  ProductError,
} from "@/lib/products";
import { json, error } from "@/lib/http";

/** Creates the product the capture flow just photographed (SPEC §10 step 2). */
export async function POST(request: Request) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  let body: unknown;
  try {
    body = JSON.parse((await readLimitedBody(request, 4 * 1024 * 1024 + 16384)).toString("utf8"));
  } catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
    return error("Invalid request body.");
  }

  const validation = validateCreateProduct((body ?? {}) as Record<string, unknown>);
  if (!validation.ok) return error(validation.error);

  try {
    if (validation.value.cutout) await ensureCutoutBucket();
    const product = await createProduct(claims.orgId, validation.value);
    return json(product, 201);
  } catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
    return error(e instanceof Error ? e.message : "Could not save the product.", 500);
  }
}

/** The Products tab. Newest first; the app mirrors these into SwiftData (§9). */
export async function GET(request: Request) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  const page = Number(new URL(request.url).searchParams.get("page") ?? "0");
  if (!Number.isSafeInteger(page) || page < 0 || page > 1_000_000) return error("Invalid products page.");
  const pageSize = 100;
  const db = supabaseAdmin();
  const { data, error: dbError } = await db
    .from("products")
    .select("id, name, category, cutout_url, created_at, attributes")
    .eq("org_id", claims.orgId)
    .or("attributes->>captureStatus.is.null,attributes->>captureStatus.eq.ready,attributes->>captureStatus.eq.deleting")
    .order("created_at", { ascending: false })
    .order("id", { ascending: false })
    .range(page * pageSize, page * pageSize + pageSize);
  if (dbError) return error("Could not load your products.", 500);

  return json({
    hasMore: (data?.length ?? 0) > pageSize,
    products: (data ?? []).slice(0, pageSize).map((row) => ({
      id: row.id as string,
      name: row.name as string,
      category: (row.category as string | null) ?? null,
      cutoutPath: (row.cutout_url as string | null) ?? null,
      createdAt: row.created_at as string,
      isHidden: row.attributes?.hidden === true,
      deletionPending: row.attributes?.captureStatus === "deleting",
    })),
  });
}
