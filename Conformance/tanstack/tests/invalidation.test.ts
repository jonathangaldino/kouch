import { describe, expect, it } from 'vitest'
import { advance, client, controlled, immediate, observe, settle } from './helpers'

describe('invalidation', () => {
  it('[inv-001] active queries refetch, inactive become stale', async () => {
    const qc = client()
    const f1 = immediate(() => 'one')
    const f2 = immediate(() => 'two')
    observe(qc, { queryKey: ['todos', 1], queryFn: f1.fn, staleTime: Infinity })
    await qc.fetchQuery({ queryKey: ['todos', 2], queryFn: f2.fn, staleTime: Infinity })
    await settle()
    await qc.invalidateQueries({ queryKey: ['todos'] })
    expect(qc.getQueryState(['todos', 1])!.isInvalidated).toBe(false) // refetched → cleared
    expect(qc.getQueryState(['todos', 2])!.isInvalidated).toBe(true)
    expect(f1.count).toBe(2)
    expect(f2.count).toBe(1)
    observe(qc, { queryKey: ['todos', 2], queryFn: f2.fn, staleTime: Infinity })
    await settle()
    expect(f2.count).toBe(2)
  })

  it('[inv-002] filter scope', async () => {
    const qc = client()
    const t = immediate(() => 't')
    const p = immediate(() => 'p')
    observe(qc, { queryKey: ['todos'], queryFn: t.fn, staleTime: Infinity })
    observe(qc, { queryKey: ['posts'], queryFn: p.fn, staleTime: Infinity })
    await settle()
    await qc.invalidateQueries({ queryKey: ['todos'] })
    expect(t.count).toBe(2)
    expect(p.count).toBe(1)
    expect(qc.getQueryState(['posts'])!.isInvalidated).toBe(false)
  })

  it('[inv-003] refetchType', async () => {
    const qc = client()
    const a = immediate(() => 'a')
    const b = immediate(() => 'b')
    observe(qc, { queryKey: ['a'], queryFn: a.fn, staleTime: Infinity })
    await qc.fetchQuery({ queryKey: ['b'], queryFn: b.fn })
    await settle()
    await qc.invalidateQueries({ refetchType: 'none' })
    expect(a.count).toBe(1)
    expect(b.count).toBe(1)
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(true)
    expect(qc.getQueryState(['b'])!.isInvalidated).toBe(true)
    await qc.invalidateQueries({ refetchType: 'all' })
    expect(a.count).toBe(2)
    expect(b.count).toBe(2)
  })

  it('[inv-004] invalidateQueries resolves after refetch finishes', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    let calls = 0
    observe(qc, {
      queryKey: ['a'],
      queryFn: () => { calls++; return new Promise((r) => setTimeout(() => r('B'), 1000)) },
      staleTime: Infinity,
    })
    let done = false
    void qc.invalidateQueries().then(() => (done = true))
    await advance(999)
    expect(done).toBe(false)
    await advance(1)
    expect(done).toBe(true)
    expect(qc.getQueryData(['a'])).toBe('B')
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(false)
    expect(calls).toBe(1)
  })

  it('[inv-005] disabled observers are not refetched', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    observe(qc, { queryKey: ['a'], queryFn: fn.fn, enabled: false })
    await qc.invalidateQueries()
    expect(fn.count).toBe(0)
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(true)
  })

  it('[inv-006] invalidating an in-flight query with data restarts it', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: Infinity })
    void o.observer.refetch()
    await settle()
    void qc.invalidateQueries()
    await settle()
    expect(fn.count).toBe(2)
    fn.calls[0]!.resolve('old')
    await settle()
    expect(qc.getQueryData(['a'])).toBe('A')
    fn.calls[1]!.resolve('new')
    await settle()
    expect(qc.getQueryData(['a'])).toBe('new')
  })

  it('[inv-007] setQueryData clears invalidation', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    await qc.invalidateQueries()
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(true)
    qc.setQueryData(['a'], 'X')
    expect(qc.getQueryState(['a'])!.isInvalidated).toBe(false)
  })
})
