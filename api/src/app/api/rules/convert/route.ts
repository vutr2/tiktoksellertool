import { verifySession } from "@/lib/session";
import { rulesFor } from "@/lib/rules/registry";
import { convert } from "@/lib/rules/convert";
import type { Asset, MarketplaceId } from "@/lib/rules/types";
import { json, error } from "@/lib/http";
import { languageFromHeader } from "@/lib/i18n";
import { parseOutputLanguage } from "@/lib/ai/types";

interface Body {
  asset?: Asset;
  from?: MarketplaceId;
  to?: MarketplaceId;
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
  if (!body.asset || !body.from || !body.to) {
    return error("asset, from and to are required.");
  }

  try {
    // TODO(M5): gate on the caller's tier — a Starter seller converting to
    // Amazon must get the paywall sheet, not a result (SPEC §6).
    // The content language is a fact about the asset and decides whether the
    // revalidation inside convert() could really check it. The interface
    // language only decides what the change list reads like.
    const content = parseOutputLanguage(body.language);
    if (!content) return error("That language is not supported yet.");
    const result = convert(body.asset, rulesFor(body.from), rulesFor(body.to), {
      content,
      messages: languageFromHeader(request.headers.get("accept-language")),
    });
    return json(result);
  } catch (e) {
    return error(e instanceof Error ? e.message : "Conversion failed.");
  }
}
