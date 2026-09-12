import { allRules } from "@/lib/rules/registry";
import { json } from "@/lib/http";

// Serves the versioned rule sets the app caches on device (SPEC §7). Public and
// unauthenticated on purpose: these are published marketplace limits, not user
// data, and the app needs them to render the marketplace picker.
export async function GET() {
  const marketplaces = allRules();
  return json({
    // Bumping any config's version invalidates the device cache.
    versions: Object.fromEntries(marketplaces.map((m) => [m.id, m.version])),
    marketplaces,
  });
}
