#!/usr/bin/env node

import { ReadableStream } from "node:stream/web";
import { pathToFileURL } from "node:url";
import path from "node:path";

const packageDir = option("--ax-package-dir");
if (!packageDir) fail("--ax-package-dir is required");

const ax = await import(pathToFileURL(path.resolve(packageDir, "index.js")));
const packageJson = await import(
  pathToFileURL(path.resolve(packageDir, "package.json")),
  { with: { type: "json" } }
);

if (packageJson.default.version !== "23.0.0") {
  fail(`expected @ax-llm/ax 23.0.0, got ${packageJson.default.version}`);
}

const signature = ax.s(
  'question:string, tags?:string[] -> label:class "yes, no", score:number'
);

const tool = {
  name: "lookup",
  description: "Lookup a value",
  parameters: {
    type: "object",
    properties: { key: { type: "string", description: "lookup key" } },
    required: ["key"],
  },
  func: async ({ key }) => ({ found: true, key }),
};
const processor = new ax.AxFunctionProcessor([tool]);
const toolResult = await processor.execute({
  id: "call-1",
  name: "lookup",
  args: '{"key":"alpha"}',
});

let unknownToolError;
try {
  await processor.execute({ id: "call-2", name: "missing", args: "{}" });
} catch (error) {
  unknownToolError = {
    name: error?.name,
    recoverable: error?.name === "ValidationError",
    listsAvailableTool: String(error?.message).includes("Available functions: lookup"),
  };
}
if (!unknownToolError) fail("unknown Ax tool did not fail");

const targets = [
  { id: "recent::instruction", kind: "instruction", current: "a" },
  { id: "stale::instruction", kind: "instruction", current: "b" },
];
const selector = new ax.AxGEPAComponentSelector(targets);
selector.recordProposal("recent::instruction");
selector.recordResult("recent::instruction", true, 5);
for (let iteration = 0; iteration < 4; iteration += 1) {
  selector.recordProposal("stale::instruction");
  selector.recordResult("stale::instruction", false, iteration);
}
const restored = new ax.AxGEPAComponentSelector(targets, selector.snapshot());

const result = {
  schema_version: 1,
  runtime: {
    package: "@ax-llm/ax",
    version: packageJson.default.version,
    provider_calls: 0,
  },
  cases: {
    typed_signature: {
      inputs: normalizeFields(signature.getInputFields()),
      outputs: normalizeFields(signature.getOutputFields()),
    },
    structured_output: normalizeSchema(signature.toJSONSchema()),
    streaming_optional: {
      omitted: await streamingCase(ax, [
        { index: 0, content: "Required Field: only " },
        { index: 0, content: "required", finishReason: "stop" },
      ]),
      present: await streamingCase(ax, [
        { index: 0, content: "Required Field: required\n" },
        { index: 0, content: "Optional Field: present", finishReason: "stop" },
      ]),
    },
    tools: {
      objectResult: JSON.parse(toolResult),
      unknownToolError,
    },
    usage: ax.axNormalizeOpenAIUsage({
      input_tokens: 120,
      output_tokens: 30,
      total_tokens: 150,
      input_tokens_details: { cached_tokens: 20 },
      output_tokens_details: { reasoning_tokens: 7 },
    }),
    optimizer_selection: {
      snapshot: restored.snapshot(),
      pickAtHalf: restored.pick(10, () => 0.5).id,
    },
  },
};

process.stdout.write(`${JSON.stringify(result)}\n`);

async function streamingCase(api, chunks) {
  const stream = new ReadableStream({
    start(controller) {
      chunks.forEach((chunk, index) => {
        controller.enqueue({
          results: [chunk],
          modelUsage: {
            ai: "fixture",
            model: "fixture",
            tokens: {
              promptTokens: 10 + index,
              completionTokens: 5 + index,
              totalTokens: 15 + 2 * index,
            },
          },
        });
      });
      controller.close();
    },
  });
  const ai = new api.AxMockAIService({
    features: { functions: false, streaming: true },
    chatResponse: stream,
  });
  const gen = new api.AxGen(
    "userInput:string -> requiredField:string, optionalField?:string"
  );
  return await gen.forward(
    ai,
    { userInput: "fixture" },
    { stream: true, strictMode: false }
  );
}

function normalizeFields(fields) {
  return fields.map((field) => ({
    name: field.name,
    type: field.type?.name ?? "string",
    array: field.type?.isArray ?? false,
    optional: field.isOptional ?? false,
    options: field.type?.options ?? [],
  }));
}

function normalizeSchema(schema) {
  return {
    type: schema.type,
    required: schema.required ?? [],
    properties: Object.fromEntries(
      Object.entries(schema.properties ?? {}).map(([name, value]) => [
        name,
        {
          type: value.type,
          enum: value.enum ?? [],
          items: value.items?.type ?? null,
        },
      ])
    ),
  };
}

function option(name) {
  const index = process.argv.indexOf(name);
  return index < 0 ? null : process.argv[index + 1];
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}
