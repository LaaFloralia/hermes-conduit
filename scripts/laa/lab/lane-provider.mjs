// Sole provider in the lab Work catalog: no tool, process, file or network I/O.
export function open(ctx) {
  return {
    async turn({ text, messageId }) {
      ctx.emit({ type: 'session', sessionId: `lab-${ctx.agentId}` });
      ctx.emit({ type: 'runtime', model: ctx.model });
      ctx.emit({ type: 'assistant', text: `Lab Echo: ${text}`, messageId: `lab-${messageId}` });
      return { status: 'completed' };
    },
    async interrupt() {},
    async close() {},
  };
}
