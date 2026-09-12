// Lists every marketplace limit still awaiting the real spec (SPEC §7).
// Run with: npm run rules:todos
import { pendingVerifications } from "../src/lib/rules/registry.ts";

const pending = pendingVerifications();
let current = "";
for (const item of pending) {
  if (item.marketplace !== current) {
    current = item.marketplace;
    console.log(`\n${current}`);
  }
  console.log(`  ${item.path}`);
  if (item.source) console.log(`      ${item.source}`);
}
console.log(`\n${pending.length} value groups need verification before launch.`);
