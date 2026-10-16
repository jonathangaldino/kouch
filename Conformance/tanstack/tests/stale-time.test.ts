import { describe, expect, it } from 'vitest'
import { advance, client, controlled, immediate, observe, settle } from './helpers'

describe('stale-time', () => {
  it('[stale-001] default staleTime 0: stale immediately', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn })
    await settle()
    expect(o.current.status).toBe('success')
    expect(o.current.isStale).toBe(true)
  })

  it('[stale-002] boundary of staleTime', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn, staleTime: 1000 })
    await settle()
    await advance(999)
    expect(o.current.isStale).toBe(false)
    await advance(2)
    expect(o.current.isStale).toBe(true)
  })

  it('[stale-003] staleTime Infinity', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn, staleTime: Infinity })
    await settle()
    await advance(24 * 3600 * 1000)
    expect(o.current.isStale).toBe(false)
    await qc.invalidateQueries({ refetchType: 'none' })
    expect(o.current.isStale).toBe(true)
  })

  it('[stale-004] staleTime "static" survives invalidation', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn, staleTime: 'static' })
    await settle()
    await qc.invalidateQueries({ refetchType: 'none' })
    expect(o.current.isStale).toBe(false)
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(true)
  })

  it('[stale-005] no data is stale; disabled observer is not', async () => {
    const qc = client()
    const q = qc.getQueryCache().build(qc, { queryKey: ['a'] })
    expect(q.isStale()).toBe(true)
    const o = observe(qc, { queryKey: ['b'], queryFn: controlled().fn, enabled: false })
    await settle()
    expect(o.current.isStale).toBe(false)
  })

  it('[stale-006] mount behavior follows freshness', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await advance(500)
    const o1 = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: 1000 })
    await settle()
    expect(fn.count).toBe(1)
    o1.unsubscribe()
    await advance(1000)
    observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: 1000 })
    await settle()
    expect(fn.count).toBe(2)
  })

  it('[stale-007] query is stale if any observer considers it stale', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    const o1 = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: Infinity })
    const o2 = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: 1000 })
    await advance(1001)
    expect(o1.current.isStale).toBe(false)
    expect(o2.current.isStale).toBe(true)
    const q = qc.getQueryCache().find({ queryKey: ['a'] })!
    expect(q.isStale()).toBe(true)
    expect(qc.getQueryCache().findAll({ stale: true })).toContain(q)
  })
})
