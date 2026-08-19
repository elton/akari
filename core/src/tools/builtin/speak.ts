import type { SpeechHost, ToolDefinition } from "../types.ts";

/** 🟢 GREEN — say something out loud. Output only; nothing changes. */
export function speakTool(speech: SpeechHost): ToolDefinition {
  return {
    name: "speak",
    description:
      "Say something out loud in akari's voice. Use it to read text back to " +
      "the user or to talk while a slower tool runs. Text only, no markup.",
    parameters: {
      type: "object",
      properties: {
        text: {
          type: "string",
          minLength: 1,
          maxLength: 2000,
          description: "What to say, as plain spoken language.",
        },
      },
      required: ["text"],
      additionalProperties: false,
    },
    risk: "green",
    mutating: false,
    async run(args, context) {
      const text = args["text"] as string;
      await speech.speak(text, context.signal);
      return { ok: true, content: `Spoke ${text.length} characters.` };
    },
  };
}
