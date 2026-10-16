import { describe, expect, it } from 'vitest'
import { onlineManager } from '@tanstack/query-core'
import { advance, client, controlled, failing, immediate, observe, settle } from './helpers'

describe('network-mode', () => {
  it('[net-001] offline start pauses', async () => {
    const qc = client()
    qc.mount()
    onlineManager.setOnline(false)
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    expect(o.current.status).toBe('pending')
    expect(o.current.fetchStatus).toBe('paused')
    expect(o.current.isPaused).toBe(true)
    expect(fn.count).toBe(0)
    onlineManager.setOnline(true)
    await settle()
    expect(fn.count).toBe(1)
    expect(o.current.fetchStatus).toBe('fetching')
    await fn.resolveLast('A')
    expect(o.current.status).toBe('success')
  })

  it('[net-002] networkMode always', async () => {
    const qc = client()
    onlineManager.setOnline(false)
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, networkMode: 'always' })
    await settle()
    expect(fn.count).toBe(1)
    expect(o.current.fetchStatus).toBe('fetching')
  })

  it('[net-003] networkMode offlineFirst', async () => {
    const qc = client()
    onlineManager.setOnline(false)
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, networkMode: 'offlineFirst', retry: 1, retryDelay: 10 })
    await settle()
    await advance(10)
    expect(fn.count).toBe(1)
    expect(o.current.fetchStatus).toBe('paused')
  })

  it('[net-004] reconnect refetches stale active queries', async () => {
    const qc = client()
    qc.mount()
    const stale = immediate(() => 's')
    const fresh = immediate(() => 'f')
    observe(qc, { queryKey: ['stale'], queryFn: stale.fn })
    observe(qc, { queryKey: ['fresh'], queryFn: fresh.fn, staleTime: Infinity })
    await settle()
    onlineManager.setOnline(false)
    onlineManager.setOnline(true)
    await settle()
    expect(stale.count).toBe(2)
    expect(fresh.count).toBe(1)
    qc.unmount()
  })

  it('[net-005] leaving a paused initial fetch cancels it', async () => {
    const qc = client()
    onlineManager.setOnline(false)
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    o.unsubscribe()
    onlineManager.setOnline(true)
    await settle()
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('pending')
    expect(s.fetchStatus).toBe('idle')
    expect(fn.count).toBe(0)
  })

  it('[net-006] fetchQuery while offline waits for the network', async () => {
    const qc = client()
    qc.mount()
    onlineManager.setOnline(false)
    const fn = controlled()
    let result: unknown
    void qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn }).then((d) => (result = d))
    await advance(10_000)
    expect(result).toBeUndefined()
    expect(qc.getQueryState(['a'])!.fetchStatus).toBe('paused')
    expect(fn.count).toBe(0)
    onlineManager.setOnline(true)
    await settle()
    await fn.resolveLast('A')
    expect(result).toBe('A')
  })
})
