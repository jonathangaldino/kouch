import { describe, expect, it } from 'vitest'
import { advance, client, controlled, failing, immediate, observe, settle, T0 } from './helpers'

describe('query-client', () => {
  it('[client-001] fetchQuery fetches, caches and resolves', async () => {
    const qc = client()
    const data = await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn })
    expect(data).toBe('A')
    expect(qc.getQueryData(['a'])).toBe('A')
  })

  it('[client-002] fetchQuery returns fresh cached data without calling fn', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await advance(500)
    expect(await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn, staleTime: 1000 })).toBe('A')
    expect(fn.count).toBe(1)
    await advance(500)
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn, staleTime: 1000 })
    expect(fn.count).toBe(2)
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    expect(fn.count).toBe(3)
  })

  it('[client-003] fetchQuery does not retry by default', async () => {
    const qc = client()
    const fn = failing()
    await expect(qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })).rejects.toThrow('E')
    expect(fn.count).toBe(1)
  })

  it('[client-004] prefetchQuery never throws', async () => {
    const qc = client()
    await expect(qc.prefetchQuery({ queryKey: ['a'], queryFn: failing().fn })).resolves.toBeUndefined()
    expect(qc.getQueryState(['a'])!.status).toBe('error')
  })

  it('[client-005] ensureQueryData', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = immediate(() => 'fetched')
    expect(await qc.ensureQueryData({ queryKey: ['a'], queryFn: fn.fn })).toBe('A')
    expect(fn.count).toBe(0)
    expect(await qc.ensureQueryData({ queryKey: ['missing'], queryFn: fn.fn })).toBe('fetched')
    expect(fn.count).toBe(1)
    const fn2 = controlled()
    expect(await qc.ensureQueryData({ queryKey: ['a'], queryFn: fn2.fn, revalidateIfStale: true })).toBe('A')
    await settle()
    expect(fn2.count).toBe(1)
  })

  it('[client-006] getQueryData / setQueryData', () => {
    const qc = client()
    expect(qc.getQueryData(['none'])).toBeUndefined()
    expect(qc.getQueryCache().getAll()).toHaveLength(0)
    expect(qc.setQueryData(['a'], 'A')).toBe('A')
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.data).toBe('A')
    expect(s.dataUpdatedAt).toBe(T0)
    expect(s.fetchStatus).toBe('idle')
    let received: unknown
    qc.setQueryData<string>(['a'], (prev) => {
      received = prev
      return prev + '!'
    })
    expect(received).toBe('A')
    expect(qc.getQueryData(['a'])).toBe('A!')
    expect(qc.setQueryData(['a'], () => undefined)).toBeUndefined()
    expect(qc.getQueryData(['a'])).toBe('A!')
    qc.setQueryData(['b'], 'B', { updatedAt: 42 })
    expect(qc.getQueryState(['b'])!.dataUpdatedAt).toBe(42)
  })

  it('[client-007] setQueryData updates observers without fetching', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, staleTime: Infinity })
    await settle()
    qc.setQueryData(['a'], 'B')
    expect(o.results.at(-1).data).toBe('B')
    expect(fn.count).toBe(1)
  })

  it('[client-008] setQueryData during an in-flight fetch', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    qc.setQueryData(['a'], 'manual')
    expect(qc.getQueryState(['a'])!.data).toBe('manual')
    expect(qc.getQueryState(['a'])!.fetchStatus).toBe('fetching')
    await fn.resolveLast('server')
    expect(qc.getQueryState(['a'])!.data).toBe('server')
    expect(qc.getQueryState(['a'])!.fetchStatus).toBe('idle')
  })

  it('[client-009] getQueryState and removeQueries', () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    expect(qc.getQueryState(['a'])!.status).toBe('success')
    qc.removeQueries({ queryKey: ['a'] })
    expect(qc.getQueryState(['a'])).toBeUndefined()
    expect(qc.getQueryData(['a'])).toBeUndefined()
  })

  it('[client-010] isFetching counts fetching queries', async () => {
    const qc = client()
    const fa = controlled()
    const fb = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fa.fn })
    void qc.prefetchQuery({ queryKey: ['b'], queryFn: fb.fn })
    await settle()
    expect(qc.isFetching()).toBe(2)
    expect(qc.isFetching({ queryKey: ['a'] })).toBe(1)
    await fa.resolveLast('A')
    await fb.resolveLast('B')
    expect(qc.isFetching()).toBe(0)
  })

  it('[client-011] default options', async () => {
    const qc = client({ defaultOptions: { queries: { staleTime: 1000 } } })
    qc.setQueryDefaults(['todos'], { staleTime: Infinity })
    const todos = immediate(() => 't')
    const other = immediate(() => 'o')
    await qc.fetchQuery({ queryKey: ['todos', 1], queryFn: todos.fn })
    await qc.fetchQuery({ queryKey: ['other'], queryFn: other.fn })
    await advance(5000)
    await qc.fetchQuery({ queryKey: ['todos', 1], queryFn: todos.fn })
    await qc.fetchQuery({ queryKey: ['other'], queryFn: other.fn })
    expect(todos.count).toBe(1)
    expect(other.count).toBe(2)
  })
})
