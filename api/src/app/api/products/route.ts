import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import {
  createProduct,
  ensureCutoutBucket,
  validateCreateProduct,
<<<<<<< HEAD
  readLimitedBody,
  ProductError,
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
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
<<<<<<< HEAD
    body = JSON.parse((await readLimitedBody(request, 4 * 1024 * 1024 + 16384)).toString("utf8"));
  } catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
=======
    body = await request.json();
  } catch {
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
    return error("Invalid request body.");
  }

  const validation = validateCreateProduct((body ?? {}) as Record<string, unknown>);
  if (!validation.ok) return error(validation.error);

  try {
    if (validation.value.cutout) await ensureCutoutBucket();
    const product = await createProduct(claims.orgId, validation.value);
    return json(product, 201);
  } catch (e) {
<<<<<<< HEAD
    if (e instanceof ProductError) return error(e.message, e.status);
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
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

  const db = supabaseAdmin();
  const { data, error: dbError } = await db
    .from("products")
    .select("id, name, category, cutout_url, created_at")
    .eq("org_id", claims.orgId)
<<<<<<< HEAD
    .or("attributes->>captureStatus.is.null,attributes->>captureStatus.eq.ready")
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
    .order("created_at", { ascending: false })
    .limit(100);
  if (dbError) return error("Could not load your products.", 500);

  return json({
    products: (data ?? []).map((row) => ({
      id: row.id as string,
      name: row.name as string,
      category: (row.category as string | null) ?? null,
      cutoutPath: (row.cutout_url as string | null) ?? null,
      createdAt: row.created_at as string,
    })),
  });
}
