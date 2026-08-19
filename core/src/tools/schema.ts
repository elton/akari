/**
 * A small JSON Schema checker for tool arguments.
 *
 * Deliberately not ajv: the arguments a model produces are shallow objects, and
 * the subset below covers every schema the tool registry accepts. Unsupported
 * keywords are ignored rather than rejected, so a schema can carry extra
 * documentation keywords for the model without breaking validation.
 *
 * Supported: type (object/array/string/number/integer/boolean/null), properties,
 * required, additionalProperties:false, enum, items, minItems, maxItems,
 * minLength, maxLength, pattern, minimum, maximum.
 */

export interface ValidationResult {
  ok: boolean;
  errors: string[];
}

type Schema = Record<string, unknown>;

export function validateArgs(schema: Schema, value: unknown): ValidationResult {
  const errors: string[] = [];
  check(schema, value, "arguments", errors);
  return { ok: errors.length === 0, errors };
}

function check(
  schema: Schema,
  value: unknown,
  path: string,
  errors: string[],
): void {
  const type = schema["type"];
  if (typeof type === "string" && !matchesType(type, value)) {
    errors.push(`${path}: expected ${type}, got ${describe(value)}`);
    return;
  }

  const options = schema["enum"];
  if (Array.isArray(options) && !options.some((o) => o === value)) {
    errors.push(`${path}: must be one of ${JSON.stringify(options)}`);
  }

  if (typeof value === "string") checkString(schema, value, path, errors);
  if (typeof value === "number") checkNumber(schema, value, path, errors);
  if (Array.isArray(value)) checkArray(schema, value, path, errors);
  if (isPlainObject(value)) checkObject(schema, value, path, errors);
}

function checkString(
  schema: Schema,
  value: string,
  path: string,
  errors: string[],
): void {
  const min = schema["minLength"];
  const max = schema["maxLength"];
  const pattern = schema["pattern"];
  if (typeof min === "number" && value.length < min) {
    errors.push(`${path}: shorter than minLength ${min}`);
  }
  if (typeof max === "number" && value.length > max) {
    errors.push(`${path}: longer than maxLength ${max}`);
  }
  if (typeof pattern === "string" && !new RegExp(pattern).test(value)) {
    errors.push(`${path}: does not match ${pattern}`);
  }
}

function checkNumber(
  schema: Schema,
  value: number,
  path: string,
  errors: string[],
): void {
  const min = schema["minimum"];
  const max = schema["maximum"];
  if (typeof min === "number" && value < min) {
    errors.push(`${path}: below minimum ${min}`);
  }
  if (typeof max === "number" && value > max) {
    errors.push(`${path}: above maximum ${max}`);
  }
}

function checkArray(
  schema: Schema,
  value: unknown[],
  path: string,
  errors: string[],
): void {
  const min = schema["minItems"];
  const max = schema["maxItems"];
  if (typeof min === "number" && value.length < min) {
    errors.push(`${path}: fewer than minItems ${min}`);
  }
  if (typeof max === "number" && value.length > max) {
    errors.push(`${path}: more than maxItems ${max}`);
  }
  const items = schema["items"];
  if (isPlainObject(items)) {
    value.forEach((entry, i) => check(items, entry, `${path}[${i}]`, errors));
  }
}

function checkObject(
  schema: Schema,
  value: Record<string, unknown>,
  path: string,
  errors: string[],
): void {
  const properties = isPlainObject(schema["properties"])
    ? schema["properties"]
    : {};
  // Own properties only, everywhere. `key in value` also finds what Object's
  // prototype provides, so `{}` would satisfy `required: ["toString"]`, and
  // `{"constructor": "evil"}` would slip past `additionalProperties: false`
  // because `"constructor" in properties` is true for any object literal.
  const required = schema["required"];
  if (Array.isArray(required)) {
    for (const key of required) {
      if (typeof key === "string" && !Object.hasOwn(value, key)) {
        errors.push(`${path}: missing required property "${key}"`);
      }
    }
  }
  if (schema["additionalProperties"] === false) {
    for (const key of Object.keys(value)) {
      if (!Object.hasOwn(properties, key)) {
        errors.push(`${path}: unknown property "${key}"`);
      }
    }
  }
  for (const [key, sub] of Object.entries(properties)) {
    if (!Object.hasOwn(value, key) || !isPlainObject(sub)) continue;
    check(sub, value[key], `${path}.${key}`, errors);
  }
}

function matchesType(type: string, value: unknown): boolean {
  switch (type) {
    case "object":
      return isPlainObject(value);
    case "array":
      return Array.isArray(value);
    case "string":
      return typeof value === "string";
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "boolean":
      return typeof value === "boolean";
    case "null":
      return value === null;
    default:
      // Unknown type keyword: not our business to reject.
      return true;
  }
}

function describe(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

/**
 * Keys that must never survive into a tool's arguments. `JSON.parse` happily
 * produces an own `__proto__` property, and while a spread copies it
 * harmlessly, one `Object.assign(target, args)` anywhere downstream turns it
 * into prototype pollution. `constructor` and `prototype` are dropped for the
 * same reason: a model has no business naming them, so losing them costs
 * nothing.
 */
const DANGEROUS_KEYS = new Set(["__proto__", "constructor", "prototype"]);

/**
 * Copy of `value` with the dangerous keys removed at every depth.
 *
 * Applied to every tool call before validation and before the arguments are
 * frozen, so this holds regardless of which provider parsed the JSON.
 */
export function sanitizeToolArgs<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeToolArgs(entry)) as unknown as T;
  }
  if (!isPlainObject(value)) return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value)) {
    if (DANGEROUS_KEYS.has(key)) continue;
    out[key] = sanitizeToolArgs(value[key]);
  }
  return out as unknown as T;
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" && value !== null && !Array.isArray(value)
  );
}
