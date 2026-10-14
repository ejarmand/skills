// Declines a retry after a provider rate limit or overload when the provider
// asks for a longer wait than the runner's grace, so OpenCode fails the run
// with that error instead of waiting it out silently (#68).
const LIMITED = new Set([429, 503, 529])

export default {
  id: "decline-long-retry",
  setup: async (ctx) => {
    const graceMs = ctx.options.graceMs
    await ctx.session.hook("retry", (event) => {
      if (!LIMITED.has(event.error.status) || !event.decision.retry) return
      if (event.decision.delay > graceMs) event.decision = { retry: false }
    })
  },
}
