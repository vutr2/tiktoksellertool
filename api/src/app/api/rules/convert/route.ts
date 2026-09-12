import { verifySession } from "@/lib/session";
import { rulesFor } from "@/lib/rules/registry";
import { convert } from "@/lib/rules/convert";
import type { Asset, MarketplaceId } from "@/lib/rules/types";
import { json, error } from "@/lib/http";

interface Body {
  asset?: Asset;
  from?: MarketplaceId;
  to?: MarketplaceId;
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
  if (!body.asset || !body.from || !body.to) {
    return error("asset, from and to are required.");
  }

  try {
    // TODO(M5): gate on the caller's tier — a Starter seller converting to
    // Amazon must get the paywall sheet, not a result (SPEC §6).
    const result = convert(body.asset, rulesFor(body.from), rulesFor(body.to));
    return json(result);
  } catch (e) {
    return error(e instanceof Error ? e.message : "Conversion failed.");
  }
}
