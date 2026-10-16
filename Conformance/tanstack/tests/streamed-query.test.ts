import { describe, expect, it } from 'vitest'
import { experimental_streamedQuery as streamedQuery } from '@tanstack/query-core'
import { client, observe, settle } from './helpers'

/** An async iterable the test feeds chunk by chunk. */
function channel<T>(opts: { readSignal?: boolean } = {}) {
  const queue: T[] = []
  let wake: (() => void) | undefined
  let done = false
  let signal: AbortSignal | undefined
  let calls = 0
  return {
    get calls() { return calls },
    get signal() { return signal },
    streamFn: (ctx: any) => {
      calls++
      if (opts.readSignal) signal = ctx.signal
      done = false
      return {
        async *[Symbol.asyncIterator]() {
          while (true) {
            if (queue.length) { yield queue.shift()!; continue }
            if (done) return
            await new Promise<void>((r) => (wake = r))
          }
        },
      }
    },
    push: async (value: T) => { queue.push(value); wake?.(); await settle() },
    end: async () => { done = true; wake?.(); await settle() },
  }
}

describe('streamed-query', () => {
  it('[sq-001] chunks are appended as they arrive', async () => {
    const qc = client()
    const ch = channel<string>()
    const o = observe(qc, { queryKey: ['s'], queryFn: streamedQuery({ streamFn: ch.streamFn }) })
    await settle()
    expect(o.current.status).toBe('pending')
    await ch.push('a')
    expect(o.current.data).toEqual(['a'])
    expect(o.current.status).toBe('success')
    expect(o.current.fetchStatus).toBe('fetching')
    await ch.push('b')
    expect(o.current.data).toEqual(['a', 'b'])
    await ch.end()
    expect(o.current.data).toEqual(['a', 'b'])
    expect(o.current.fetchStatus).toBe('idle')
  })

  it('[sq-002] refetchMode reset (default) clears data when a refetch starts', async () => {
    const qc = client()
    const ch = channel<string>()
    const o = observe(qc, { queryKey: ['s'], queryFn: streamedQuery({ streamFn: ch.streamFn }) })
    await settle()
    await ch.push('a')
    await ch.end()
    void o.observer.refetch()
    await settle()
    expect(o.current.status).toBe('pending')
    expect(o.current.data).toBeUndefined()
    expect(o.current.fetchStatus).toBe('fetching')
    await ch.push('b')
    expect(o.current.data).toEqual(['b'])
    await ch.end()
  })

  it('[sq-003] refetchMode append keeps old data and appends', async () => {
    const qc = client()
    const ch = channel<string>()
    const o = observe(qc, { queryKey: ['s'], queryFn: streamedQuery({ streamFn: ch.streamFn, refetchMode: 'append' }) })
    await settle()
    await ch.push('a')
    await ch.end()
    void o.observer.refetch()
    await settle()
    expect(o.current.data).toEqual(['a'])
    await ch.push('b')
    expect(o.current.data).toEqual(['a', 'b'])
    await ch.end()
  })

  it('[sq-004] refetchMode replace swaps data in once the stream ends', async () => {
    const qc = client()
    const ch = channel<string>()
    const o = observe(qc, { queryKey: ['s'], queryFn: streamedQuery({ streamFn: ch.streamFn, refetchMode: 'replace' }) })
    await settle()
    await ch.push('a')
    await ch.end()
    void o.observer.refetch()
    await settle()
    await ch.push('b')
    await ch.push('c')
    expect(o.current.data).toEqual(['a'])
    await ch.end()
    expect(o.current.data).toEqual(['b', 'c'])
  })

  it('[sq-005] reducer and initialValue', async () => {
    const qc = client()
    const ch = channel<number>()
    const o = observe(qc, {
      queryKey: ['sum'],
      queryFn: streamedQuery({ streamFn: ch.streamFn, reducer: (acc: number, n: number) => acc + n, initialValue: 0 }),
    })
    await settle()
    await ch.push(2)
    await ch.push(3)
    expect(o.current.data).toBe(5)
    await ch.end()
    expect(o.current.data).toBe(5)
  })

  it('[sq-006] cancelling mid-stream keeps received chunks and stops listening', async () => {
    const qc = client()
    const ch = channel<string>({ readSignal: true })
    observe(qc, { queryKey: ['s'], queryFn: streamedQuery({ streamFn: ch.streamFn }) })
    await settle()
    await ch.push('a')
    await qc.cancelQueries()
    await ch.push('b')
    const s = qc.getQueryState(['s'])!
    expect(s.data).toEqual(['a'])
    expect(s.status).toBe('success')
    expect(s.fetchStatus).toBe('idle')
    expect(ch.signal!.aborted).toBe(true)
  })
})
