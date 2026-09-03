import type { ChatStreamCallbacks } from "./tools/executor.ts";

const STREAM_CHUNK_SIZE = 8;

function pause(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function emitTextAsStream(
  onToken: (delta: string) => void,
  text: string,
): Promise<void> {
  if (!text) return;
  for (let i = 0; i < text.length; i += STREAM_CHUNK_SIZE) {
    onToken(text.slice(i, i + STREAM_CHUNK_SIZE));
    await pause(36);
  }
}

export async function finalizeStreamedContent(
  stream: ChatStreamCallbacks | undefined,
  content: string,
  streamedLive: boolean,
): Promise<void> {
  if (!stream?.onToken || streamedLive || !content) return;
  await emitTextAsStream(stream.onToken, content);
}
