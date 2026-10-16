import { vi } from 'vitest'
import { QueryClient, QueryObserver } from '@tanstack/query-core'
import type { QueryCacheConfig, QueryClientConfig, QueryFunctionContext, QueryObserverOptions } from '@tanstack/query-core'

export const T0 = 1_000_000

/** Let pending promises run without moving virtual time. */
export const settle = () => vi.advanceTimersByTimeAsync(0)
/** Move virtual time forward, firing timers and settling promises. */
export const advance = (ms: number) => vi.advanceTimersByTimeAsync(ms)
export const now = () => Date.now()

export interface Call<T> {
  key: readonly unknown[]
  ctx: QueryFunctionContext
  signal?: AbortSignal
  resolve: (value: T) => void
  reject: (error: unknown) => void
}

/** A query function whose calls the test resolves/rejects manually. */
export function controlled<T = string>(opts: { readSignal?: boolean } = {}) {
  const calls: Call<T>[] = []
  const fn = (ctx: QueryFunctionContext): Promise<T> =>
    new Promise<T>((resolve, reject) => {
      const signal = opts.readSignal ? ctx.signal : undefined
      calls.push({ key: ctx.queryKey, ctx, signal, resolve, reject })
    })
  return {
    fn,
    calls,
    get count() {
      return calls.length
    },
    last: () => calls[calls.length - 1]!,
    resolveLast: async (value: T) => {
      calls[calls.length - 1]!.resolve(value)
      await settle()
    },
    rejectLast: async (error: unknown) => {
      calls[calls.length - 1]!.reject(error)
      await settle()
    },
  }
}

/** A query function that resolves immediately with `value(callIndex)`. */
export function immediate<T>(value: (n: number) => T) {
  let count = 0
  const fn = vi.fn(async () => value(count++))
  return { fn, get count() { return count } }
}

/** A query function that always rejects. */
export function failing(message = 'E') {
  let count = 0
  const times: number[] = []
  const fn = async () => {
    count++
    times.push(Date.now())
    throw new Error(message)
  }
  return { fn, times, get count() { return count } }
}

export function client(config: QueryClientConfig = {}) {
  return new QueryClient(config)
}

export function cacheConfig(c: QueryCacheConfig) {
  return c
}

/** Subscribe an observer, recording every result. */
export function observe<T>(qc: QueryClient, options: QueryObserverOptions<any, any, T, any, any>) {
  const observer = new QueryObserver(qc, options)
  const results: any[] = []
  const unsubscribe = observer.subscribe((r) => results.push(r))
  return { observer, results, unsubscribe, get current() { return observer.getCurrentResult() } }
}
