/**
 * Provider interfaces (ADR-003): every leg — LLM, ASR, TTS, realtime — can be
 * swapped for a local implementation without touching business code.
 *
 * Default implementations target DashScope (Model Studio); the local path is
 * MLX with `orcarouter/Qwen3.8-27B-Uncensored-MLX` 6-bit. The local model is
 * multimodal and does function calling, so "local" is a full path, not a
 * degraded fallback.
 */

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /** Data URLs or file paths; `qwen3.7-flash` takes images natively. */
  images?: string[];
  /** Set on role "tool" to answer a specific call. */
  toolCallId?: string;
  /**
   * Content that came from outside the user (screenshots, page text, file
   * contents). Any state-changing tool call made after reading untrusted
   * content is forced through the confirmation gate (spec.md §4.4).
   */
  untrusted?: boolean;
}

export interface ToolSchema {
  name: string;
  description: string;
  /** JSON Schema for the arguments object. */
  parameters: Record<string, unknown>;
}

export interface ChatRequest {
  messages: ChatMessage[];
  tools?: ToolSchema[];
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
}

export interface ChatChunk {
  /** Incremental assistant text. */
  text?: string;
  toolCall?: { callId: string; name: string; arguments: Record<string, unknown> };
  done?: boolean;
}

export interface LLMProvider {
  readonly id: string;
  /** True when inference happens on this machine — drives the privacy badge. */
  readonly local: boolean;
  chat(request: ChatRequest): AsyncIterable<ChatChunk>;
}

export interface ASRProvider {
  readonly id: string;
  readonly local: boolean;
  /** pcm is PCM16LE at `sampleRate`. */
  transcribe(pcm: Uint8Array, sampleRate: number): Promise<string>;
}

export interface TTSProvider {
  readonly id: string;
  readonly local: boolean;
  /** Yields PCM16LE chunks at the provider's own sample rate. */
  synthesize(text: string, voice?: string): AsyncIterable<Uint8Array>;
}

/** Everything the rest of the core is allowed to depend on. */
export interface Providers {
  llm: LLMProvider;
  /** Absent when voice runs end-to-end through Realtime (the v1 default). */
  asr?: ASRProvider;
  tts?: TTSProvider;
}
