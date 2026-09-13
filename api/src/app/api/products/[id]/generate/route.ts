import { verifySession } from "@/lib/session";
import { generateListings, quoteCredits } from "@/lib/generate";
import { InsufficientCreditsError } from "@/lib/credits";
import { MARKETPLACE_IDS } from "@/lib/rules/registry";
import type { MarketplaceId } from "@/lib/rules/types";
import { json, error } from "@/lib/http";

interface Body {
  marketplaces?: unknown;
  scriptCount?: unknown;
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  const { id } = await context.params;

  let body: Body;
  try {
    body = await request.json();
  } catch {
    return error("Invalid request body.");
  }

  const marketplaces = Array.isArray(body.marketplaces)
    ? body.marketplaces.filter((m): m is MarketplaceId =>
        typeof m === "string" && (MARKETPLACE_IDS as string[]).includes(m))
    : [];
  if (marketplaces.length === 0) return error("Pick at least one marketplace.");

  const scriptCount =
    typeof body.scriptCount === "number" && Number.isInteger(body.scriptCount)
      ? Math.max(0, Math.min(10, body.scriptCount))
      : 0;

  try {
    const result = await generateListings(claims.orgId, { productId: id, marketplaces, scriptCount });
    return json(result);
  } catch (e) {
    if (e instanceof InsufficientCreditsError) {
      // The app shows the paywall here, not an error (SPEC §6).
      return json(
        { error: e.message, required: e.required, available: e.available },
        402,
      );
    }
    return error(e instanceof Error ? e.message : "Generation failed.", 500);
  }
}

/** What the work would cost — shown before the seller commits (design step 3). */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }
  await context.params;

  const url = new URL(request.url);
  const marketplaces = (url.searchParams.get("marketplaces") ?? "")
    .split(",")
    .filter((m): m is MarketplaceId => (MARKETPLACE_IDS as string[]).includes(m));
  const scriptCount = Number(url.searchParams.get("scriptCount") ?? 0) || 0;

  return json({ credits: quoteCredits({ productId: "", marketplaces, scriptCount }) });
}
