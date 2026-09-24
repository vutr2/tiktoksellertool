import { verifySession } from "@/lib/session";
import { deleteProduct, setProductHidden } from "@/lib/product-management";
import { ProductError, readLimitedBody } from "@/lib/products";
import { error, json } from "@/lib/http";

type Context = { params: Promise<{ id: string }> };
export const maxDuration = 60;
export async function DELETE(request: Request, context: Context) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  try {
    const id = (await context.params).id.toLowerCase();
    await deleteProduct(claims.orgId, id);
    return json({ deleted: true });
  } catch (e) { return error(e instanceof ProductError ? e.message : "Could not delete this product.", e instanceof ProductError ? e.status : 500); }
}

export async function PATCH(request: Request, context: Context) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  let body;
  try { body = JSON.parse((await readLimitedBody(request, 1024)).toString("utf8")); }
  catch { return error("Invalid product update."); }
  if (typeof body?.hidden !== "boolean") return error("Choose whether to hide this product.");
  try {
    const id = (await context.params).id.toLowerCase();
    await setProductHidden(claims.orgId, id, body.hidden);
    return json({ hidden: body.hidden });
  } catch (e) { return error(e instanceof ProductError ? e.message : "Could not update this product.", e instanceof ProductError ? e.status : 500); }
}
