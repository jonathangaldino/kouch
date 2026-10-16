import { describe, expect, it } from 'vitest'
import { QueriesObserver } from '@tanstack/query-core'
import { client, controlled, immediate, observe, settle } from './helpers'

function queries(qc: any, list: any[], options?: any) {
  const observer = new QueriesObserver(qc, list, options)
  const results: any[][] = []
  const unsubscribe = observer.subscribe((r) => results.push(r))
  return { observer, results, unsubscribe }
}

describe('queries-observer', () => {
  it('[qs-001] results in input order; each query fetched once', async () => {
    const qc = client()
    const a = controlled()
    const b = controlled()
    const o = queries(qc, [{ queryKey: ['a'], queryFn: a.fn }, { queryKey: ['b'], queryFn: b.fn }])
    await settle()
    expect(a.count).toBe(1)
    expect(b.count).toBe(1)
    const before = o.results.length
    await a.resolveLast('A')
    expect(o.results.length).toBeGreaterThan(before)
    const mid = o.results.length
    await b.resolveLast('B')
    expect(o.results.length).toBeGreaterThan(mid)
    expect(o.observer.getCurrentResult().map((r) => r.data)).toEqual(['A', 'B'])
  })

  it('[qs-002] shares the cache with other observers', async () => {
    const qc = client()
    const fn = controlled()
    observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    queries(qc, [{ queryKey: ['a'], queryFn: fn.fn }])
    await settle()
    expect(fn.count).toBe(1)
  })

  it('[qs-003] setQueries adds and removes entries', async () => {
    const qc = client()
    const a = immediate(() => 'A')
    const b = immediate(() => 'B')
    const c = controlled()
    const o = queries(qc, [
      { queryKey: ['a'], queryFn: a.fn, staleTime: Infinity },
      { queryKey: ['b'], queryFn: b.fn, staleTime: Infinity },
    ])
    await settle()
    o.observer.setQueries([
      { queryKey: ['b'], queryFn: b.fn, staleTime: Infinity },
      { queryKey: ['c'], queryFn: c.fn, staleTime: Infinity },
    ])
    await settle()
    const cache = qc.getQueryCache()
    expect(cache.find({ queryKey: ['a'] })!.getObserversCount()).toBe(0)
    expect(cache.find({ queryKey: ['b'] })!.getObserversCount()).toBe(1)
    expect(b.count).toBe(1)
    expect(c.count).toBe(1)
    expect(o.observer.getQueries().map((q) => q.queryKey)).toEqual([['b'], ['c']])
  })

  it('[qs-004] reordering keeps observers', async () => {
    const qc = client()
    const a = immediate(() => 'A')
    const b = immediate(() => 'B')
    const qa = { queryKey: ['a'], queryFn: a.fn, staleTime: Infinity }
    const qb = { queryKey: ['b'], queryFn: b.fn, staleTime: Infinity }
    const o = queries(qc, [qa, qb])
    await settle()
    o.observer.setQueries([qb, qa])
    await settle()
    expect(a.count).toBe(1)
    expect(b.count).toBe(1)
    expect(o.observer.getCurrentResult().map((r) => r.data)).toEqual(['B', 'A'])
  })

  it('[qs-005] combine', async () => {
    const qc = client()
    const a = controlled()
    const b = controlled()
    const combine = (rs: any[]) => rs.every((r) => r.isSuccess)
    const list = [{ queryKey: ['a'], queryFn: a.fn }, { queryKey: ['b'], queryFn: b.fn }]
    const o = queries(qc, list, { combine })
    await settle()
    const combined = () => o.observer.getOptimisticResult(list.map((l) => qc.defaultQueryOptions(l)), combine)[1]()
    expect(combined()).toBe(false)
    await a.resolveLast('A')
    await b.resolveLast('B')
    expect(combined()).toBe(true)
  })

  it('[qs-006] unsubscribing unmounts every entry', async () => {
    const qc = client()
    const o = queries(qc, [{ queryKey: ['a'], queryFn: controlled().fn }, { queryKey: ['b'], queryFn: controlled().fn }])
    await settle()
    o.unsubscribe()
    const cache = qc.getQueryCache()
    expect(cache.find({ queryKey: ['a'] })!.getObserversCount()).toBe(0)
    expect(cache.find({ queryKey: ['b'] })!.getObserversCount()).toBe(0)
  })

  it('[qs-007] entries succeed and fail independently', async () => {
    const qc = client()
    const ok = controlled()
    const bad = controlled()
    const o = queries(qc, [
      { queryKey: ['ok'], queryFn: ok.fn, retry: false },
      { queryKey: ['bad'], queryFn: bad.fn, retry: false },
    ])
    await settle()
    await ok.resolveLast('A')
    await bad.rejectLast(new Error('E'))
    expect(o.observer.getCurrentResult().map((r) => r.status)).toEqual(['success', 'error'])
  })
})
