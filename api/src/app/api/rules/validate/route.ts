import { verifySession } from "@/lib/session";
import { rulesFor } from "@/lib/rules/registry";
import { statusOf, validate } from "@/lib/rules/validate";
import type { Asset, MarketplaceId } from "@/lib/rules/types";
import { json, error } from "@/lib/http";
import { languageFromHeader } from "@/lib/i18n";
import { parseOutputLanguage } from "@/lib/ai/types";

interface Body {
  marketplace?: MarketplaceId;
  asset?: Asset;
  /** The language the asset is written in. Absent means English, which is what
   *  every listing saved before the app had a second language actually was. */
  language?: string;
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
    // Two separate languages. The content language decides whether the
    // engine's English word lists could see this text at all — reading the app
    // in English must never make Vietnamese copy report as fully checked. The
    // interface language only decides what the explanation is written in.
    const content = parseOutputLanguage(body.language);
    if (!content) return error("That language is not supported yet.");
    const violations = validate(body.asset, rulesFor(body.marketplace), {
      content,
      messages: languageFromHeader(request.headers.get("accept-language")),
    });
    // `status` is the pass/warn/fail badge the Review screen shows per asset.
    return json({ status: statusOf(violations), violations });
  } catch (e) {
    return error(e instanceof Error ? e.message : "Validation failed.");
  }
}
