import { corsHeaders } from "../cors.ts";

export type SseWriter = {
  send: (event: string, data: unknown) => void;
  close: () => void;
};

export function createSseStream(
  handler: (writer: SseWriter) => Promise<void>,
): Response {
  const encoder = new TextEncoder();
  let closed = false;

  const stream = new ReadableStream({
    async start(controller) {
      const writer: SseWriter = {
        send(event: string, data: unknown) {
          if (closed) return;
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
          );
        },
        close() {
          if (closed) return;
          closed = true;
          controller.close();
        },
      };

      try {
        await handler(writer);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        writer.send("error", { message });
      } finally {
        writer.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...corsHeaders,
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}
