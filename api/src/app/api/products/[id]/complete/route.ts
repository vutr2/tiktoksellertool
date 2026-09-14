import { verifySession } from "@/lib/session";
import { completeProduct, ProductError } from "@/lib/products";
import { json, error } from "@/lib/http";

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  try { return json(await completeProduct(claims.orgId, id)); }
  catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
    return error("Could not finish saving your product. Retry this draft.", 500);
  }
}
