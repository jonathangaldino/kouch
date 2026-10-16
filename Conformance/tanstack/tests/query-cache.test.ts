import { describe, expect, it } from 'vitest'
import { QueryCache } from '@tanstack/query-core'
import { client, controlled, immediate, observe, settle } from './helpers'

describe('query-cache', () => {
  it('[cache-001] build is idempotent per key', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    const events: string[] = []
    cache.subscribe((e) => events.push(e.type))
    const a = cache.build(qc, { queryKey: ['a'] })
    const b = cache.build(qc, { queryKey: ['a'] })
    expect(a).toBe(b)
    expect(cache.getAll()).toHaveLength(1)
    expect(events.filter((e) => e === 'added')).toHaveLength(1)
  })

  it('[cache-002] find defaults to exact matching', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    const todos = cache.build(qc, { queryKey: ['todos'] })
    const todo1 = cache.build(qc, { queryKey: ['todos', 1] })
    expect(cache.find({ queryKey: ['todos'] })).toBe(todos)
    expect(cache.find({ queryKey: ['todos', 1] })).toBe(todo1)
    expect(cache.find({ queryKey: ['nope'] })).toBeUndefined()
  })

  it('[cache-003] findAll filters by type, stale and fetchStatus', async () => {
    const qc = client()
    const cache = qc.getQueryCache()
    observe(qc, { queryKey: ['active'], queryFn: immediate(() => 'x').fn, staleTime: Infinity })
    await qc.fetchQuery({ queryKey: ['inactive'], queryFn: immediate(() => 'y').fn })
    void qc.fetchQuery({ queryKey: ['fetching'], queryFn: controlled().fn })
    await settle()
    const k = (f: any) => cache.findAll(f).map((q) => q.queryKey[0]).sort()
    expect(k({ type: 'active' })).toEqual(['active'])
    expect(k({ type: 'inactive' })).toEqual(['fetching', 'inactive'])
    expect(k({ stale: false })).toEqual(['active', 'inactive'])
    expect(k({ fetchStatus: 'fetching' })).toEqual(['fetching'])
    expect(k({ predicate: (q: any) => q.queryKey[0] === 'inactive' })).toEqual(['inactive'])
  })

  it('[cache-004] cache events', async () => {
    const qc = client()
    const events: string[] = []
    qc.getQueryCache().subscribe((e) => {
      if (['added', 'updated', 'removed'].includes(e.type)) events.push(e.type)
    })
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn })
    qc.removeQueries({ queryKey: ['a'] })
    expect(events).toEqual(['added', 'updated', 'updated', 'removed'])
  })

  it('[cache-005] remove and clear', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    const a = cache.build(qc, { queryKey: ['a'] })
    cache.build(qc, { queryKey: ['b'] })
    cache.remove(a)
    expect(cache.find({ queryKey: ['a'] })).toBeUndefined()
    expect(cache.getAll()).toHaveLength(1)
    cache.clear()
    expect(cache.getAll()).toHaveLength(0)
  })

  it('[cache-006] cache-level callbacks', async () => {
    const calls: any[] = []
    const queryCache = new QueryCache({
      onSuccess: (data, q) => calls.push(['success', data, q.queryKey[0]]),
      onError: (error, q) => calls.push(['error', error.message, q.queryKey[0]]),
      onSettled: (data, error, q) => calls.push(['settled', data, error?.message ?? null, q.queryKey[0]]),
    })
    const qc = client({ queryCache })
    await qc.fetchQuery({ queryKey: ['ok'], queryFn: immediate(() => 'A').fn })
    await qc.fetchQuery({ queryKey: ['bad'], queryFn: async () => { throw new Error('E') } }).catch(() => {})
    expect(calls).toEqual([
      ['success', 'A', 'ok'],
      ['settled', 'A', null, 'ok'],
      ['error', 'E', 'bad'],
      ['settled', undefined, 'E', 'bad'],
    ])
  })
})
