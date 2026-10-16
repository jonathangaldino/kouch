import { describe, expect, it } from 'vitest'
import { client, controlled, immediate, observe, settle } from './helpers'

describe('deduplication', () => {
  it('[dedup-001] two consumers request the same query', async () => {
    const qc = client()
    const fn = controlled()
    const a = observe(qc, { queryKey: ['user', 123], queryFn: fn.fn })
    const b = observe(qc, { queryKey: ['user', 123], queryFn: fn.fn })
    await settle()
    expect(fn.count).toBe(1)
    expect(a.observer.getCurrentQuery()).toBe(b.observer.getCurrentQuery())
    for (const o of [a, b]) {
      expect(o.current.status).toBe('pending')
      expect(o.current.fetchStatus).toBe('fetching')
    }
    await fn.resolveLast('user')
    expect(a.current.data).toBe('user')
    expect(b.current.data).toBe('user')
    expect(qc.getQueryCache().getAll()).toHaveLength(1)
  })

  it('[dedup-002] concurrent fetchQuery calls share one request', async () => {
    const qc = client()
    const fn = controlled()
    const p1 = qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    const p2 = qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    expect(fn.count).toBe(1)
    await fn.resolveLast('A')
    expect(await p1).toBe('A')
    expect(await p2).toBe('A')
  })

  it('[dedup-003] observer and fetchQuery share one request', async () => {
    const qc = client()
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    const p = qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    expect(fn.count).toBe(1)
    await fn.resolveLast('A')
    expect(await p).toBe('A')
    expect(o.current.data).toBe('A')
  })

  it('[dedup-004] refetch with cancelRefetch: false joins the in-flight request', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: Infinity })
    void o.observer.refetch()
    await settle()
    void o.observer.refetch({ cancelRefetch: false })
    await settle()
    expect(fn.count).toBe(1)
  })

  it('[dedup-005] cancelRefetch replaces an in-flight request only when data exists', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: Infinity })
    void o.observer.refetch()
    await settle()
    void o.observer.refetch()
    await settle()
    expect(fn.count).toBe(2)
    fn.calls[0]!.resolve('old')
    await settle()
    expect(qc.getQueryData(['a'])).toBe('A')
    fn.calls[1]!.resolve('new')
    await settle()
    expect(qc.getQueryData(['a'])).toBe('new')

    const fn2 = controlled()
    const o2 = observe(qc, { queryKey: ['b'], queryFn: fn2.fn })
    await settle()
    void o2.observer.refetch()
    await settle()
    expect(fn2.count).toBe(1)
  })

  it('[dedup-006] a completed request is not reused', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    expect(fn.count).toBe(2)
  })
})
