import { describe, expect, it } from 'vitest'
import { focusManager, onlineManager } from '@tanstack/query-core'
import { advance, client, failing, observe, settle, T0 } from './helpers'

describe('retries', () => {
  it('[retry-001] default: 3 retries with exponential backoff', async () => {
    const qc = client()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    expect(o.current.failureCount).toBe(1)
    expect(o.current.status).toBe('pending')
    expect(o.current.fetchStatus).toBe('fetching')
    await advance(7000)
    expect(fn.times).toEqual([T0, T0 + 1000, T0 + 3000, T0 + 7000])
    expect(o.current.status).toBe('error')
    expect(o.current.error?.message).toBe('E')
    expect(o.current.failureCount).toBe(4)
    expect(fn.count).toBe(4)
  })

  it('[retry-002] retry: false makes one attempt', async () => {
    const qc = client()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: false })
    await advance(10_000)
    expect(fn.count).toBe(1)
    expect(o.current.status).toBe('error')
  })

  it('[retry-003] retry: N', async () => {
    const qc = client()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: 1, retryDelay: 10 })
    await advance(1000)
    expect(fn.count).toBe(2)
    expect(o.current.status).toBe('error')
  })

  it('[retry-004] retry function', async () => {
    const qc = client()
    const retry = (failureCount: number, error: Error) => error.message === 'retryable' && failureCount < 2
    const r = failing('retryable')
    observe(qc, { queryKey: ['a'], queryFn: r.fn, retry, retryDelay: 10 })
    await advance(1000)
    expect(r.count).toBe(3)
    const f = failing('fatal')
    observe(qc, { queryKey: ['b'], queryFn: f.fn, retry, retryDelay: 10 })
    await advance(1000)
    expect(f.count).toBe(1)
  })

  it('[retry-005] retryDelay function receives failureCount', async () => {
    const qc = client()
    const fn = failing()
    observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: 2, retryDelay: (n: number) => (n + 1) * 100 })
    await advance(1000)
    expect(fn.times).toEqual([T0, T0 + 100, T0 + 300])
  })

  it('[retry-006] success after retry resets failures', async () => {
    const qc = client()
    let n = 0
    const o = observe(qc, {
      queryKey: ['a'],
      queryFn: async () => {
        if (n++ === 0) throw new Error('E')
        return 'A'
      },
      retry: 3,
      retryDelay: 10,
    })
    await settle()
    expect(o.current.failureCount).toBe(1)
    expect(o.current.failureReason?.message).toBe('E')
    await advance(10)
    expect(o.current.status).toBe('success')
    expect(o.current.failureCount).toBe(0)
    expect(o.current.failureReason).toBeNull()
  })

  it('[retry-007] fetchQuery does not retry unless asked', async () => {
    const qc = client()
    const a = failing()
    await qc.fetchQuery({ queryKey: ['a'], queryFn: a.fn }).catch(() => {})
    expect(a.count).toBe(1)
    const b = failing()
    const p = qc.fetchQuery({ queryKey: ['b'], queryFn: b.fn, retry: 2, retryDelay: 10 }).catch(() => {})
    await advance(100)
    await p
    expect(b.count).toBe(3)
  })

  it('[retry-008] retry pauses while offline', async () => {
    const qc = client()
    qc.mount()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: 1, retryDelay: 1000 })
    await settle()
    onlineManager.setOnline(false)
    await advance(1000)
    expect(o.current.fetchStatus).toBe('paused')
    expect(fn.count).toBe(1)
    onlineManager.setOnline(true)
    await settle()
    expect(fn.count).toBe(2)
  })

  it('[retry-009] retry pauses while unfocused', async () => {
    const qc = client()
    qc.mount()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: 1, retryDelay: 1000 })
    await settle()
    focusManager.setFocused(false)
    await advance(1000)
    expect(o.current.fetchStatus).toBe('paused')
    expect(fn.count).toBe(1)
    focusManager.setFocused(true)
    await settle()
    expect(fn.count).toBe(2)
  })

  it('[retry-010] unsubscribing stops further retries (signal not consumed)', async () => {
    const qc = client()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: 3, retryDelay: 1000 })
    await settle()
    o.unsubscribe()
    await advance(10_000)
    expect(fn.count).toBe(1)
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('error')
    expect(s.fetchStatus).toBe('idle')
  })
})
