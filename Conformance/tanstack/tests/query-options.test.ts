import { describe, expect, it } from 'vitest'
import { focusManager, MutationCache, MutationObserver, QueryCache, QueryObserver, skipToken } from '@tanstack/query-core'
import { advance, client, controlled, failing, immediate, observe, settle } from './helpers'

describe('query-options', () => {
  it('[qo-001] meta reaches the query function and cache callbacks', async () => {
    const seen: unknown[] = []
    const qc = client({ queryCache: new QueryCache({ onSuccess: (_d, q) => seen.push(q.meta) }) })
    let ctxMeta: unknown
    await qc.fetchQuery({ queryKey: ['a'], meta: { source: 'test' }, queryFn: async (ctx) => { ctxMeta = ctx.meta; return 'A' } })
    expect(ctxMeta).toEqual({ source: 'test' })
    expect(seen).toEqual([{ source: 'test' }])
    expect(qc.getQueryCache().find({ queryKey: ['a'] })!.meta).toEqual({ source: 'test' })
  })

  it('[qo-002] the query function context carries the client', async () => {
    const qc = client()
    let ctxClient: unknown
    await qc.fetchQuery({ queryKey: ['a'], queryFn: async (ctx) => { ctxClient = ctx.client; return 'A' } })
    expect(ctxClient).toBe(qc)
  })

  it('[qo-003] the mutation function context carries client, meta and key', async () => {
    const qc = client()
    let ctx: any
    const o = new MutationObserver(qc, {
      mutationKey: ['m'],
      meta: { tag: 1 },
      mutationFn: async (_v: string, c) => { ctx = c; return 'ok' },
    })
    await o.mutate('v')
    expect(ctx.client).toBe(qc)
    expect(ctx.meta).toEqual({ tag: 1 })
    expect(ctx.mutationKey).toEqual(['m'])
    expect(qc.getMutationCache().getAll()[0]!.meta).toEqual({ tag: 1 })
  })

  it('[qo-004] staleTime as a function of the query', async () => {
    const qc = client()
    qc.setQueryData(['fresh'], 'fresh')
    qc.setQueryData(['old'], 'old')
    const staleTime = (q: any) => (q.state.data === 'fresh' ? Infinity : 0)
    const f = controlled()
    const o = controlled()
    observe(qc, { queryKey: ['fresh'], queryFn: f.fn, staleTime })
    observe(qc, { queryKey: ['old'], queryFn: o.fn, staleTime })
    await settle()
    expect(f.count).toBe(0)
    expect(o.count).toBe(1)
  })

  it('[qo-005] enabled as a function of the query', async () => {
    const qc = client()
    const fn = controlled()
    let allowed = false
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, enabled: () => allowed })
    await settle()
    expect(fn.count).toBe(0)
    expect(o.current.isEnabled).toBe(false)
    allowed = true
    o.observer.setOptions({ queryKey: ['a'], queryFn: fn.fn, enabled: () => allowed })
    await settle()
    expect(fn.count).toBe(0) // the previous options' function now also says true: no "was disabled" edge
    void qc.invalidateQueries()
    await settle()
    expect(fn.count).toBe(1)
    expect(o.current.isEnabled).toBe(true)
  })

  it('[qo-006] refetchInterval as a function of the query', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    observe(qc, {
      queryKey: ['a'],
      queryFn: fn.fn,
      refetchInterval: (q: any) => (q.state.dataUpdateCount < 3 ? 1000 : false),
    })
    await settle()
    await advance(10_000)
    expect(fn.count).toBe(3)
  })

  it('[qo-007] refetchOnWindowFocus as a function of the query', async () => {
    const qc = client()
    qc.mount()
    const always = immediate(() => 'refocus')
    const never = immediate(() => 'other')
    const trigger = (q: any) => (q.state.data === 'refocus' ? 'always' : false)
    observe(qc, { queryKey: ['a'], queryFn: always.fn, staleTime: Infinity, refetchOnWindowFocus: trigger })
    observe(qc, { queryKey: ['b'], queryFn: never.fn, refetchOnWindowFocus: trigger })
    await settle()
    focusManager.setFocused(false)
    focusManager.setFocused(true)
    await settle()
    expect(always.count).toBe(2)
    expect(never.count).toBe(1)
    qc.unmount()
  })

  it('[qo-008] initialData as a function is evaluated lazily, once per query', () => {
    const qc = client()
    let calls = 0
    const initialData = () => { calls++; return 'init' }
    const q = qc.getQueryCache().build(qc, { queryKey: ['a'], initialData })
    expect(q.state.data).toBe('init')
    qc.getQueryCache().build(qc, { queryKey: ['a'], initialData })
    expect(calls).toBe(1)
  })

  it('[qo-009] retryOnMount', async () => {
    const qc = client()
    await qc.prefetchQuery({ queryKey: ['a'], queryFn: failing().fn })
    const noRetry = failing()
    observe(qc, { queryKey: ['a'], queryFn: noRetry.fn, retry: false, retryOnMount: false })
    await settle()
    expect(noRetry.count).toBe(0)
    const retry = failing()
    observe(qc, { queryKey: ['a'], queryFn: retry.fn, retry: false })
    await settle()
    expect(retry.count).toBe(1)
  })

  it('[qo-010] skipToken disables the query', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: skipToken })
    await settle()
    expect(o.current.isEnabled).toBe(false)
    expect(o.current.fetchStatus).toBe('idle')
    const q = qc.getQueryCache().find({ queryKey: ['a'] })!
    o.unsubscribe()
    expect(q.isDisabled()).toBe(true)
    const r = await new QueryObserver(qc, { queryKey: ['a'], queryFn: skipToken, retry: false }).refetch()
    expect(r.status).toBe('error')
    expect(r.error!.message).toContain('Missing queryFn')
  })

  it('[qo-011] refetch throwOnError', async () => {
    const qc = client()
    const fn = failing()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, retry: false })
    await settle()
    const r = await o.observer.refetch()
    expect(r.status).toBe('error')
    await expect(o.observer.refetch({ throwOnError: true })).rejects.toThrow('E')
  })

  it('[qo-012] refetchQueries / invalidateQueries throwOnError', async () => {
    const qc = client()
    observe(qc, { queryKey: ['a'], queryFn: failing().fn, retry: false })
    await settle()
    await expect(qc.refetchQueries()).resolves.toBeUndefined()
    await expect(qc.refetchQueries({}, { throwOnError: true })).rejects.toThrow('E')
    await expect(qc.invalidateQueries({}, { throwOnError: true })).rejects.toThrow('E')
  })

  it('[qo-013] getQueriesData / setQueriesData', () => {
    const qc = client()
    qc.setQueryData(['todos', 1], 'one')
    qc.setQueryData(['todos', 2], 'two')
    qc.setQueryData(['posts'], 'post')
    expect(qc.getQueriesData({ queryKey: ['todos'] })).toEqual([[['todos', 1], 'one'], [['todos', 2], 'two']])
    const updated = qc.setQueriesData<string>({ queryKey: ['todos'] }, (prev) => prev + '!')
    expect(updated).toEqual([[['todos', 1], 'one!'], [['todos', 2], 'two!']])
    expect(qc.getQueryData(['posts'])).toBe('post')
  })

  it('[qo-014] mutationCache.find', async () => {
    const qc = client()
    await new MutationObserver(qc, { mutationKey: ['todos', 'add'], mutationFn: async () => 'ok' }).mutate(undefined)
    const cache = qc.getMutationCache()
    expect(cache.find({ mutationKey: ['todos', 'add'] })).toBeDefined()
    expect(cache.find({ mutationKey: ['todos'] })).toBeUndefined()
    expect(cache.find({ mutationKey: ['todos'], exact: false })).toBeDefined()
    expect(cache.findAll({ mutationKey: ['todos'] })).toHaveLength(1)
  })

  it('[qo-015] mutations take mutationFn and callbacks from setMutationDefaults', async () => {
    const qc = client({ mutationCache: new MutationCache() })
    const log: string[] = []
    qc.setMutationDefaults(['add'], {
      mutationFn: async (v: unknown) => { log.push(`fn ${v}`); return 'done' },
      onSuccess: () => { log.push('defaults.onSuccess') },
    })
    const data = await new MutationObserver(qc, { mutationKey: ['add'] }).mutate('v')
    expect(data).toBe('done')
    expect(log).toEqual(['fn v', 'defaults.onSuccess'])
  })
})
