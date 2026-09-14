import { readFileSync } from "node:fs";
import { join } from "node:path";

interface BillingConfiguration {
  costs: { titleOrDescription: number; adScript: number; imageGeneration: number; marketplaceConversion: number };
  trialCredits: number;
  products: Record<string, { tier: string | null; credits: number; months: number }>;
}
export const billingConfig = JSON.parse(readFileSync(join(process.cwd(), "config", "credits.json"), "utf8")) as BillingConfiguration;
