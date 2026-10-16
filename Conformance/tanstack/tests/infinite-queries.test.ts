import { describe, expect, it } from 'vitest'
import { InfiniteQueryObserver } from '@tanstack/query-core'
import { client, controlled, settle } from './helpers'

const next = (_last: unknown, _all: unknown, lastParam: number) => (lastParam < 2 ? lastParam + 1 : undefined)

function infinite(qc: any, options: any) {
  const observer = new InfiniteQueryObserver(qc, {
    queryKey: ['list'],
    initialPageParam: 0,
    getNextPageParam: next,
    ...options,
  })
  const results: any[] = []
  const unsubscribe = observer.subscribe((r: any) => results.push(r))
  return { observer, results, unsubscribe, get current(): any { return observer.getCurrentResult() } }
}

describe('infinite-queries', () => {
  it('[inf-001] initial fetch loads the first page', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, { queryFn: fn.fn })
    await settle()
    expect(fn.count).toBe(1)
    expect((fn.last().ctx as any).pageParam).toBe(0)
    expect((fn.last().ctx as any).direction).toBe('forward')
    await fn.resolveLast('p0')
    expect(o.current.data).toEqual({ pages: ['p0'], pageParams: [0] })
    expect(o.current.hasNextPage).toBe(true)
    expect(o.current.hasPreviousPage).toBe(false)
  })

  it('[inf-002] fetchNextPage appends the next page', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, { queryFn: fn.fn })
    await settle()
    await fn.resolveLast('p0')
    void o.observer.fetchNextPage()
    await settle()
    expect(o.current.isFetchingNextPage).toBe(true)
    expect(o.current.isRefetching).toBe(false)
    expect(o.current.isFetching).toBe(true)
    expect((fn.last().ctx as any).pageParam).toBe(1)
    expect((fn.last().ctx as any).direction).toBe('forward')
    await fn.resolveLast('p1')
    expect(o.current.data.pages).toEqual(['p0', 'p1'])
    expect(o.current.data.pageParams).toEqual([0, 1])
    expect(o.current.isFetchingNextPage).toBe(false)
  })

  it('[inf-003] no next page', async () => {
    const qc = client()
    const o = infinite(qc, { queryFn: async ({ pageParam }: any) => `p${pageParam}` })
    await settle()
    await o.observer.fetchNextPage()
    await o.observer.fetchNextPage()
    expect(o.current.hasNextPage).toBe(false)
    let calls = 0
    o.observer.setOptions({ queryKey: ['list'], initialPageParam: 0, getNextPageParam: next, queryFn: async ({ pageParam }: any) => { calls++; return `p${pageParam}` } } as any)
    await o.observer.fetchNextPage()
    await settle()
    expect(calls).toBe(0)
    expect(o.current.data.pages).toEqual(['p0', 'p1', 'p2'])
  })

  it('[inf-004] fetchPreviousPage prepends', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, {
      queryFn: fn.fn,
      initialPageParam: 5,
      getNextPageParam: () => undefined,
      getPreviousPageParam: (_f: unknown, _a: unknown, firstParam: number) => firstParam - 1,
    })
    await settle()
    await fn.resolveLast('p5')
    expect(o.current.hasPreviousPage).toBe(true)
    void o.observer.fetchPreviousPage()
    await settle()
    expect(o.current.isFetchingPreviousPage).toBe(true)
    expect((fn.last().ctx as any).pageParam).toBe(4)
    expect((fn.last().ctx as any).direction).toBe('backward')
    await fn.resolveLast('p4')
    expect(o.current.data.pages).toEqual(['p4', 'p5'])
    expect(o.current.data.pageParams).toEqual([4, 5])
  })

  it('[inf-005] refetch reloads every page in order', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, { queryFn: fn.fn, staleTime: Infinity })
    await settle()
    await fn.resolveLast('p0')
    void o.observer.fetchNextPage()
    await settle()
    await fn.resolveLast('p1')
    void o.observer.refetch()
    await settle()
    expect(fn.count).toBe(3)
    expect((fn.last().ctx as any).pageParam).toBe(0)
    await fn.resolveLast('p0-v2')
    expect(fn.count).toBe(4)
    expect((fn.last().ctx as any).pageParam).toBe(1)
    await fn.resolveLast('p1-v2')
    expect(o.current.data.pages).toEqual(['p0-v2', 'p1-v2'])
    expect(o.current.data.pageParams).toEqual([0, 1])
  })

  it('[inf-006] refetch stops when there is no next page anymore', async () => {
    const qc = client()
    let stop = false
    let calls = 0
    const queryFn = async ({ pageParam }: any) => { calls++; return `p${pageParam}` }
    const getNextPageParam = (l: unknown, a: unknown, p: number) => (stop ? undefined : next(l, a, p))
    const o = infinite(qc, { queryFn, getNextPageParam, staleTime: Infinity })
    await settle()
    await o.observer.fetchNextPage()
    await o.observer.fetchNextPage()
    expect(o.current.data.pageParams).toEqual([0, 1, 2])
    stop = true
    calls = 0
    await o.observer.refetch()
    expect(calls).toBe(1)
    expect(o.current.data.pages).toHaveLength(1)
  })

  it('[inf-007] maxPages', async () => {
    const qc = client()
    const o = infinite(qc, { queryFn: async ({ pageParam }: any) => `p${pageParam}`, maxPages: 2 })
    await settle()
    await o.observer.fetchNextPage()
    await o.observer.fetchNextPage()
    expect(o.current.data.pageParams).toEqual([1, 2])
    expect(o.current.data.pages).toEqual(['p1', 'p2'])
  })

  it('[inf-008] fetchNextPage error', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, { queryFn: fn.fn, retry: false })
    await settle()
    await fn.resolveLast('p0')
    void o.observer.fetchNextPage()
    await settle()
    await fn.rejectLast(new Error('E'))
    expect(o.current.status).toBe('error')
    expect(o.current.isFetchNextPageError).toBe(true)
    expect(o.current.isRefetchError).toBe(false)
    expect(o.current.data.pages).toEqual(['p0'])
  })

  it('[inf-009] fetchInfiniteQuery with pages', async () => {
    const qc = client()
    let calls = 0
    const data = await qc.fetchInfiniteQuery({
      queryKey: ['list'],
      queryFn: async ({ pageParam }: any) => { calls++; return `p${pageParam}` },
      initialPageParam: 0,
      getNextPageParam: next,
      pages: 3,
    })
    expect(data.pageParams).toEqual([0, 1, 2])
    expect(calls).toBe(3)
  })

  it('[inf-010] fetchNextPage joins an in-flight fetch with cancelRefetch: false', async () => {
    const qc = client()
    const fn = controlled()
    const o = infinite(qc, { queryFn: fn.fn })
    await settle()
    await fn.resolveLast('p0')
    void o.observer.fetchNextPage()
    await settle()
    void o.observer.fetchNextPage({ cancelRefetch: false })
    await settle()
    expect(fn.count).toBe(2)
  })
})
