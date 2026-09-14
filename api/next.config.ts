import type { NextConfig } from "next";

const nextConfig: NextConfig = {
<<<<<<< HEAD
  distDir: process.env.NEXT_DIST_DIR || ".next",
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
  /**
   * Keep the OpenTelemetry stack out of the bundler.
   *
   * Bundling the OTel packages makes webpack try to resolve Node built-ins
   * (`stream`, `fs`) reached through their transitive dependencies, which fails
   * the whole app rather than just tracing. Listing them leaves them as runtime
   * requires.
   */
<<<<<<< HEAD
  outputFileTracingIncludes: { "/api/**/*": ["./config/credits.json", "./config/apple/*.cer"] },
  serverExternalPackages: [
    "@apple/app-store-server-library",
=======
  serverExternalPackages: [
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
    "@opentelemetry/sdk-trace-node",
    "@opentelemetry/api",
    "@langfuse/otel",
    "@langfuse/tracing",
  ],
};

export default nextConfig;
