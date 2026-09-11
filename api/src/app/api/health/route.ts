import { json } from "@/lib/http";

export async function GET() {
  return json({ ok: true });
}
