import { randomUUID } from "node:crypto";
import { verifySession, assertActiveOrganization } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { ProductError, readLimitedBody } from "@/lib/products";
import { json, error } from "@/lib/http";

/** Reports stay with the owned product, including automatic account deletion. */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  let body;
  try { body = JSON.parse((await readLimitedBody(request, 32768)).toString("utf8")); }
  catch (e) { return error(e instanceof ProductError ? e.message : "Could not read the report."); }
  if (!body || typeof body !== "object" || Array.isArray(body) ||
      typeof body.assetId !== "string" || body.assetId.length > 150 ||
      typeof body.reason !== "string" || !body.reason.trim() || body.reason.length > 1000 ||
      typeof body.marketplace !== "string" || body.marketplace.length > 100 ||
      !["title", "description", "script"].includes(body.type) ||
      (body.content !== undefined && (typeof body.content !== "string" || body.content.length > 20000))) {
    return error("Choose the listing and explain what should be reviewed (up to 1,000 characters).");
  }
  const db = supabaseAdmin();
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const { data: product, error: readError } = await db.from("products").select("attributes")
        .eq("id", id).eq("org_id", claims.orgId).maybeSingle();
      if (readError) return error("Could not load the listing to report. Try again.", 500);
      if (!product) return error("That product could not be found.", 404);
      const attributes = product.attributes ?? {};
      const reports = Array.isArray(attributes.contentReports) ? attributes.contentReports : [];
      if (reports.some((report: { assetId?: string; reason?: string }) => report.assetId === body.assetId && report.reason === body.reason.trim())) {
        return json({ ok: true });
      }
      if (reports.length >= 100) return error("Please contact support for further help with this product.", 429);
      await assertActiveOrganization(claims.orgId);
      const report = { id: randomUUID(), assetId: body.assetId, reason: body.reason.trim(),
        marketplace: body.marketplace, type: body.type, content: body.content ?? null,
        createdAt: new Date().toISOString(), status: "pending" };
      const { data, error: writeError } = await db.from("products")
        .update({ attributes: { ...attributes, contentReports: [...reports, report] } })
        .eq("id", id).eq("org_id", claims.orgId).eq("attributes", JSON.stringify(attributes))
        .select("id").maybeSingle();
      if (writeError) return error("Could not send your report. Try again.", 500);
      if (data) return json({ ok: true });
    }
    return error("The listing changed. Try sending your report again.", 409);
  } catch { return error("Could not send your report. Try again.", 500); }
}
