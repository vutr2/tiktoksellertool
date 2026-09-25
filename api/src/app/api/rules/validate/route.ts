import { verifySession } from "@/lib/session";
import { rulesFor } from "@/lib/rules/registry";
import { statusOf, validate } from "@/lib/rules/validate";
import type { Asset, MarketplaceId } from "@/lib/rules/types";
import { json, error } from "@/lib/http";
import { languageFromHeader } from "@/lib/i18n";

interface Body {
  marketplace?: MarketplaceId;
  asset?: Asset;
}

export async function POST(request: Request) {
  try {
    await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  let body: Body;
  try {
    body = await request.json();
  } catch {
    return error("Invalid request body.");
  }
  if (!body.marketplace || !body.asset) {
    return error("marketplace and asset are required.");
  }

  try {
    // The free check explains rules to the seller, so it answers in the
    // language they are reading the app in.
    const language = languageFromHeader(request.headers.get("accept-language"));
    const violations = validate(body.asset, rulesFor(body.marketplace), language);
    // `status` is the pass/warn/fail badge the Review screen shows per asset.
    return json({ status: statusOf(violations), violations });
  } catch (e) {
    return error(e instanceof Error ? e.message : "Validation failed.");
  }
}
