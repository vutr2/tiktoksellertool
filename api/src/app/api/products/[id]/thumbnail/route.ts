import sharp from "sharp";
import { verifySession } from "@/lib/session";
import { managedProduct, ownsProductPhoto } from "@/lib/product-management";
import { CUTOUT_BUCKET, ProductError } from "@/lib/products";
import { supabaseAdmin } from "@/lib/supabase";
import { error } from "@/lib/http";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  try {
    const id = (await context.params).id.toLowerCase();
    const product = await managedProduct(claims.orgId, id);
    if (product.attributes.captureStatus === "deleting" || !product.cutout_url ||
        !ownsProductPhoto(claims.orgId, id, product.cutout_url)) return error("No product photo available.", 404);
    const { data, error: downloadError } = await supabaseAdmin().storage.from(CUTOUT_BUCKET).download(product.cutout_url);
    if (downloadError || !data) return error("Could not load this photo.", 503);
    const thumbnail = await sharp(Buffer.from(await data.arrayBuffer()))
      .resize(512, 512, { fit: "inside", withoutEnlargement: true }).webp({ quality: 82 }).toBuffer();
    return new Response(new Uint8Array(thumbnail), { headers: {
      "Content-Type": "image/webp", "Cache-Control": "private, max-age=300", "Vary": "Authorization",
    } });
  } catch (e) { return error(e instanceof ProductError ? e.message : "Could not load this photo.", e instanceof ProductError ? e.status : 500); }
}
