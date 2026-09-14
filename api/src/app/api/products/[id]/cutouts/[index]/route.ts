import { verifySession } from "@/lib/session";
import { MAX_CUTOUT_BYTES, ProductError, readLimitedBody, uploadProductCutout } from "@/lib/products";
import { json, error } from "@/lib/http";

export async function PUT(request: Request, context: { params: Promise<{ id: string; index: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id, index } = await context.params;
  if (!/^[0-2]$/.test(index)) return error("Choose a photo from this capture series.");
  if (request.headers.get("content-type")?.split(";")[0].trim() !== "image/png") {
    return error("Upload a PNG cutout.", 415);
  }
  try {
    const bytes = await readLimitedBody(request, MAX_CUTOUT_BYTES);
    await uploadProductCutout(claims.orgId, id, Number(index), bytes);
    return json({ ok: true });
  } catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
    return error("Could not upload this photo. Retry the same draft.", 500);
  }
}
