// Next.js calls register() once per server process.
//
// Langfuse's v5 SDK rides on OpenTelemetry, so the exporter has to be started
// here — without it `tracedGeneration` still builds spans correctly but nothing
// ever leaves the process.
//
// `NodeTracerProvider`, not `NodeSDK`: the full SDK drags in every OTLP
// exporter including the gRPC one, and webpack cannot resolve the Node
// built-ins those need. That failure is not confined to tracing — it breaks the
// whole app, every route answering 404 then 500. Langfuse's span processor
// exports over HTTP by itself, so the lighter provider is all that is needed.

export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  if (!process.env.LANGFUSE_PUBLIC_KEY || !process.env.LANGFUSE_SECRET_KEY) {
    console.info("[langfuse] keys not set — model calls will run untraced.");
    return;
  }

  const { NodeTracerProvider } = await import("@opentelemetry/sdk-trace-node");
  const { LangfuseSpanProcessor } = await import("@langfuse/otel");

  const provider = new NodeTracerProvider({
    spanProcessors: [new LangfuseSpanProcessor()],
  });
  provider.register();
  console.info("[langfuse] tracing enabled.");
}
