import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  distDir: process.env.NEXT_DIST_DIR || ".next",
  /**
   * Keep the OpenTelemetry stack out of the bundler.
   *
   * Bundling the OTel packages makes webpack try to resolve Node built-ins
   * (`stream`, `fs`) reached through their transitive dependencies, which fails
   * the whole app rather than just tracing. Listing them leaves them as runtime
   * requires.
   */
  outputFileTracingIncludes: { "/api/**/*": ["./config/credits.json", "./config/apple/*.cer"] },
  serverExternalPackages: [
    "@apple/app-store-server-library",
    "@opentelemetry/sdk-trace-node",
    "@opentelemetry/api",
    "@langfuse/otel",
    "@langfuse/tracing",
  ],
};

export default nextConfig;
