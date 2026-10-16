import { describe, expect, it } from 'vitest'
import { advance, client, controlled, settle, T0 } from './helpers'

describe('query-lifecycle', () => {
  it('[life-001] a new query starts pending and idle', () => {
    const qc = client()
    const q = qc.getQueryCache().build(qc, { queryKey: ['a'] })
    expect(q.state.status).toBe('pending')
    expect(q.state.fetchStatus).toBe('idle')
    expect(q.state.data).toBeUndefined()
    expect(q.state.error).toBeNull()
    expect(q.state.dataUpdatedAt).toBe(0)
    expect(q.state.dataUpdateCount).toBe(0)
    expect(q.state.errorUpdateCount).toBe(0)
    expect(q.state.isInvalidated).toBe(false)
  })

  it('[life-002] starting a fetch moves fetchStatus to fetching', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('pending')
    expect(s.fetchStatus).toBe('fetching')
    expect(fn.count).toBe(1)
    expect(fn.last().key).toEqual(['a'])
  })

  it('[life-003] successful fetch', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await advance(100)
    await fn.resolveLast('A')
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.fetchStatus).toBe('idle')
    expect(s.data).toBe('A')
    expect(s.error).toBeNull()
    expect(s.dataUpdatedAt).toBe(T0 + 100)
    expect(s.dataUpdateCount).toBe(1)
    expect(s.fetchFailureCount).toBe(0)
    expect(s.isInvalidated).toBe(false)
  })

  it('[life-004] failed fetch without data', async () => {
    const qc = client()
    const fn = controlled()
    const E = new Error('E')
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn, retry: 0 })
    await settle()
    await fn.rejectLast(E)
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('error')
    expect(s.fetchStatus).toBe('idle')
    expect(s.error).toBe(E)
    expect(s.data).toBeUndefined()
    expect(s.errorUpdateCount).toBe(1)
    expect(s.fetchFailureCount).toBe(1)
    expect(s.fetchFailureReason).toBe(E)
    expect(s.isInvalidated).toBe(true)
  })

  it('[life-005] failed refetch keeps previous data', async () => {
    const qc = client()
    const fn = controlled()
    qc.setQueryData(['a'], 'A')
    const E = new Error('E')
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn, retry: 0 })
    await settle()
    await fn.rejectLast(E)
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('error')
    expect(s.error).toBe(E)
    expect(s.data).toBe('A')
  })

  it('[life-006] initial data seeds a success state', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    const q = cache.build(qc, { queryKey: ['a'], initialData: 'init' })
    expect(q.state.status).toBe('success')
    expect(q.state.fetchStatus).toBe('idle')
    expect(q.state.data).toBe('init')
    expect(q.state.dataUpdatedAt).toBe(T0)
    expect(q.state.dataUpdateCount).toBe(0)
    const q2 = cache.build(qc, { queryKey: ['b'], initialData: 'init', initialDataUpdatedAt: 42 })
    expect(q2.state.dataUpdatedAt).toBe(42)
  })

  it('[life-007] refetch with data stays success while fetching', async () => {
    const qc = client()
    const fn = controlled()
    qc.setQueryData(['a'], 'A')
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    let s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.fetchStatus).toBe('fetching')
    expect(s.data).toBe('A')
    await fn.resolveLast('B')
    s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.fetchStatus).toBe('idle')
    expect(s.data).toBe('B')
    expect(s.dataUpdateCount).toBe(2)
  })

  it('[life-008] reset returns to the initial state', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await fn.resolveLast('A')
    qc.getQueryCache().build(qc, { queryKey: ['b'], initialData: 'init' })
    qc.setQueryData(['b'], 'changed')
    await qc.resetQueries()
    const a = qc.getQueryState(['a'])!
    expect(a.status).toBe('pending')
    expect(a.data).toBeUndefined()
    expect(a.dataUpdateCount).toBe(0)
    const b = qc.getQueryState(['b'])!
    expect(b.status).toBe('success')
    expect(b.data).toBe('init')
  })
})
