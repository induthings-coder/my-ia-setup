// Strips the leading "x-anthropic-billing-header: ..." block emitted by Claude
// Code on every turn. Carries a per-turn "cch=..." token that rotates the
// prompt prefix and breaks llama.cpp KV-cache reuse on the local provider.
//
// Handles both the Anthropic-shaped body (system: [{type:'text', text}, ...])
// and the OpenAI-shaped body produced after ccr's internal conversion
// (messages: [{role:'system', content}, ...]).
const PREFIX = "x-anthropic-billing-header:";

function stripText(t) {
  return typeof t === "string" && t.startsWith(PREFIX);
}

function stripContent(content) {
  if (typeof content === "string") return stripText(content);
  if (Array.isArray(content)) {
    return (
      content.length > 0 &&
      content.every(
        (b) =>
          b &&
          (b.type === "text" || b.type === undefined) &&
          stripText(b.text ?? b.content)
      )
    );
  }
  return false;
}

class StripBillingHeader {
  name = "strip-billing-header";
  endPoint = null;

  async transformRequestIn(body) {
    if (!body || typeof body !== "object") return { body };

    if (Array.isArray(body.system)) {
      body.system = body.system.filter(
        (b) => !(b && b.type === "text" && stripText(b.text))
      );
    } else if (typeof body.system === "string" && stripText(body.system)) {
      delete body.system;
    }

    if (Array.isArray(body.messages)) {
      body.messages = body.messages.filter(
        (m) => !(m && m.role === "system" && stripContent(m.content))
      );
    }

    return { body };
  }
}

module.exports = StripBillingHeader;
